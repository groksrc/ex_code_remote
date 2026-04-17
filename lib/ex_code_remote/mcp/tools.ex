defmodule ExCodeRemote.MCP.Tools do
  @moduledoc """
  MCP tool surface: definitions, validation, and dispatch.

  Tools are stateless module functions. Sync tools (`run_shell_command`,
  `read_file`, etc.) dispatch through `ExCodeRemote.Agent.dispatch/3`,
  which holds the request open until the agent replies or the timeout
  fires (50s clamp inside the dispatcher). The HTTP plug runs each
  request in its own Cowboy process, so a slow tool blocks only its own
  request, never the server.

  Async tools (`start_command`, `get_command_result`, `list_commands`)
  dispatch through `ExCodeRemote.Agent.dispatch_async/2` and read back
  via `ExCodeRemote.Audit.Queries`. `start_command` returns a
  `command_id` immediately; `get_command_result` looks up the row
  (optionally blocking via `ExCodeRemote.Commands.Subscribers` until
  the agent replies or `wait_seconds` expires).
  """

  alias ExCodeRemote.Agent
  alias ExCodeRemote.Audit.Queries
  alias ExCodeRemote.Commands.Subscribers
  alias ExCodeRemote.MCP.ResultFormatter

  # Default timeout for non-shell tools. Shell calls accept a per-call
  # `timeout` argument and clamp it (see @max_shell_timeout below).
  @default_timeout 50

  # Hard ceiling for any synchronous tool call. Fly's HTTP proxy has a
  # ~60s per-request cap that isn't governed by http_options.idle_timeout
  # and can't currently be raised via fly.toml. Capping at 50s keeps the
  # dispatcher (which adds 5s slack) replying inside Fly's window so our
  # timeout/error messages actually reach the MCP client. Commands that
  # genuinely need longer belong on the async-tools path (start_command).
  @max_shell_timeout 50

  # Async command bounds (per SPEC-10 §start_command Arguments).
  @default_async_timeout 600
  @max_async_timeout 3600

  # Cap on `wait_seconds` for `get_command_result` (per SPEC-10 — same
  # Fly-proxy reason as @max_shell_timeout).
  @max_wait_seconds 50

  # Truncation width for the `command` column in `list_commands`.
  @list_command_truncate 80

  # Width of the longest current status literal ("agent_disconnected"),
  # used for status-column padding in `list_commands` (per contracts).
  @status_column_width 18

  @valid_statuses ~w(running completed failed timeout agent_disconnected)
  @terminal_statuses ~w(completed failed timeout agent_disconnected)

  @machine_description "Target machine name (e.g. 'my-laptop', 'office-mac')"

  @tools [
    %{
      "name" => "run_shell_command",
      "description" =>
        "Execute a shell command on a remote machine and wait synchronously for the result. Use this for commands you expect to finish in under ~30 seconds. For longer commands (builds, test suites, migrations) use `start_command` instead — synchronous calls are capped at 50 seconds server-side and will fail past that.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "machine" => %{"type" => "string", "description" => @machine_description},
          "command" => %{"type" => "string", "description" => "The shell command to execute"},
          "working_dir" => %{
            "type" => "string",
            "description" =>
              "Optional working directory (defaults to home). Use ~ for home directory."
          },
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Command timeout in seconds (default 50, max 50). The server caps synchronous tool calls at 50s; longer commands should use `start_command`.",
            "default" => 50,
            "maximum" => 50
          }
        },
        "required" => ["machine", "command"]
      }
    },
    %{
      "name" => "read_file",
      "description" =>
        "Read the contents of a file on a remote machine. Returns the text content; binaries are decoded with replacement characters. Output is truncated at ~1MB with a `... (content truncated)` marker.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "machine" => %{"type" => "string", "description" => @machine_description},
          "path" => %{
            "type" => "string",
            "description" => "Path to the file. Use ~ for home directory."
          }
        },
        "required" => ["machine", "path"]
      }
    },
    %{
      "name" => "write_file",
      "description" =>
        "Write content to a file on a remote machine. Overwrites the file if it already exists; does not append. Creates parent directories if needed.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "machine" => %{"type" => "string", "description" => @machine_description},
          "path" => %{
            "type" => "string",
            "description" => "Path to the file. Use ~ for home directory."
          },
          "content" => %{"type" => "string", "description" => "Content to write to the file"}
        },
        "required" => ["machine", "path", "content"]
      }
    },
    %{
      "name" => "list_directory",
      "description" =>
        "List contents of a directory on a remote machine. Returns one entry per line, sorted, in tab-separated `<type>\\t<size>\\t<name>` format where type is `dir` or `file` and size is bytes (0 for directories).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "machine" => %{"type" => "string", "description" => @machine_description},
          "path" => %{
            "type" => "string",
            "description" => "Path to the directory. Use ~ for home directory."
          }
        },
        "required" => ["machine", "path"]
      }
    },
    %{
      "name" => "check_agent_status",
      "description" => "Check which machines are connected and ready to receive commands.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "start_command",
      "description" =>
        "Start a shell command on a remote machine asynchronously and return a command_id immediately. Use this for commands expected to take more than ~30 seconds (builds, test suites, migrations), or when you want to return a response without waiting for the command to finish. Look up the result later with `get_command_result` (by id) or browse recent commands with `list_commands`. The command keeps running on the agent regardless of whether anyone is waiting.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "machine" => %{"type" => "string", "description" => @machine_description},
          "command" => %{"type" => "string", "description" => "The shell command to execute"},
          "working_dir" => %{
            "type" => "string",
            "description" =>
              "Optional working directory (defaults to home). Use ~ for home directory."
          },
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Command timeout in seconds (default #{@default_async_timeout}, max #{@max_async_timeout}). The agent kills the process group when it fires.",
            "default" => @default_async_timeout,
            "minimum" => 1,
            "maximum" => @max_async_timeout
          }
        },
        "required" => ["machine", "command"]
      }
    },
    %{
      "name" => "get_command_result",
      "description" =>
        "Look up the status and result of a previously-started command by id. Returns the running snapshot if the command is still in flight, or the formatted terminal result (stdout/stderr/exit code or timeout/disconnect message) if it has finished. Pass `wait_seconds` to block briefly if the command is still running.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "command_id" => %{
            "type" => "string",
            "description" => "The id returned by start_command."
          },
          "wait_seconds" => %{
            "type" => "integer",
            "description" =>
              "If the command is still running, wait up to this many seconds for it to finish before responding. Capped at #{@max_wait_seconds}.",
            "default" => 0,
            "minimum" => 0,
            "maximum" => @max_wait_seconds
          }
        },
        "required" => ["command_id"]
      }
    },
    %{
      "name" => "list_commands",
      "description" =>
        "List recent commands across all agents, ordered by start time descending. Useful for finding a command_id you don't remember, or browsing what's been run on a machine. Optional filters: machine, status, limit (max 50), since (ISO-8601 timestamp).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "machine" => %{
            "type" => "string",
            "description" => "Filter to commands run on this machine."
          },
          "status" => %{
            "type" => "string",
            "enum" => @valid_statuses,
            "description" => "Filter to commands in this terminal/running state."
          },
          "limit" => %{
            "type" => "integer",
            "default" => 10,
            "minimum" => 1,
            "maximum" => 50,
            "description" => "Maximum number of rows to return (default 10, max 50)."
          },
          "since" => %{
            "type" => "string",
            "description" =>
              "ISO-8601 timestamp; only return commands started at or after this time."
          }
        }
      }
    }
  ]

  @doc "All tool definitions, ready to be returned in `tools/list`."
  @spec all() :: [map()]
  def all, do: @tools

  @doc """
  Dispatch a tool call.

  Returns:
    * `{:ok, content}` — successful, `content` is a list of MCP content items.
    * `{:tool_error, content}` — surfaced to the client as `isError: true`.
  """
  @spec call(String.t(), map()) ::
          {:ok, [map()]} | {:tool_error, [map()]}
  def call("run_shell_command", args) do
    with {:ok, machine} <- require_string(args, "machine"),
         {:ok, command} <- require_string(args, "command") do
      timeout = clamp_timeout(args["timeout"])
      working_dir = args["working_dir"]

      ctx = %{
        command: command,
        machine: machine,
        timeout: timeout,
        working_dir: working_dir
      }

      machine
      |> Agent.dispatch(
        %{type: :shell, command: command, working_dir: working_dir, timeout: timeout},
        timeout
      )
      |> shape_text(ctx)
    end
  end

  def call("read_file", args) do
    with {:ok, machine} <- require_string(args, "machine"),
         {:ok, path} <- require_string(args, "path") do
      ctx = %{machine: machine, path: path, timeout: @default_timeout}

      Agent.dispatch(machine, %{type: :read_file, path: path}, @default_timeout)
      |> shape_text(ctx)
    end
  end

  def call("write_file", args) do
    with {:ok, machine} <- require_string(args, "machine"),
         {:ok, path} <- require_string(args, "path"),
         {:ok, content} <- require_string(args, "content", allow_empty: true) do
      ctx = %{machine: machine, path: path, timeout: @default_timeout}

      Agent.dispatch(
        machine,
        %{type: :write_file, path: path, content: content},
        @default_timeout
      )
      |> shape_text(ctx)
    end
  end

  def call("list_directory", args) do
    with {:ok, machine} <- require_string(args, "machine"),
         {:ok, path} <- require_string(args, "path") do
      ctx = %{machine: machine, path: path, timeout: @default_timeout}

      Agent.dispatch(machine, %{type: :list_dir, path: path}, @default_timeout)
      |> shape_text(ctx)
    end
  end

  def call("check_agent_status", _args) do
    text =
      case Agent.list() do
        [] -> "No agents are connected."
        machines -> Enum.join(machines, ", ")
      end

    {:ok, [%{"type" => "text", "text" => text}]}
  end

  # --- Async tools (SPEC-10) ---

  def call("start_command", args) do
    with {:ok, machine} <- require_string(args, "machine"),
         {:ok, command} <- require_string(args, "command", allow_empty: true),
         {:ok, timeout, clamped_from_above?} <- validate_async_timeout(args["timeout"]) do
      working_dir = args["working_dir"]

      cmd = %{
        type: :shell,
        command: command,
        working_dir: working_dir,
        timeout: timeout
      }

      case Agent.dispatch_async(machine, cmd) do
        {:ok, command_id, started_at} ->
          header =
            render_start_header(command_id, machine, started_at, command, timeout,
              clamped_from_above?: clamped_from_above?
            )

          {:ok, [%{"type" => "text", "text" => header}]}

        {:error, :not_connected} ->
          msg =
            "No agent '#{machine}' is connected. Make sure the agent process is running and registered."

          {:tool_error, [%{"type" => "text", "text" => msg}]}

        {:error, :agent_disconnected} ->
          msg =
            "The agent '#{machine}' disconnected before the command could be dispatched. Command: #{first_line(command)}"

          {:tool_error, [%{"type" => "text", "text" => msg}]}

        {:error, reason} ->
          {:tool_error,
           [%{"type" => "text", "text" => "Failed to start command: #{inspect(reason)}"}]}
      end
    end
  end

  def call("get_command_result", args) do
    with {:ok, command_id} <- require_string(args, "command_id"),
         {:ok, wait_seconds} <- validate_wait_seconds(args["wait_seconds"]) do
      do_get_command_result(command_id, wait_seconds)
    end
  end

  def call("list_commands", args) do
    with :ok <- reject_unknown_keys(args, ~w(machine status limit since)),
         {:ok, machine} <- validate_optional_string(args, "machine"),
         {:ok, status} <- validate_status_filter(args["status"]),
         {:ok, since} <- validate_since(args["since"]),
         {:ok, limit} <- validate_limit(args["limit"]) do
      opts =
        [limit: limit]
        |> maybe_put(:machine, machine)
        |> maybe_put(:status, status)
        |> maybe_put(:since, since)

      rows = Queries.list_commands(opts)
      {:ok, [%{"type" => "text", "text" => render_list(rows)}]}
    end
  rescue
    e ->
      {:tool_error,
       [%{"type" => "text", "text" => "Audit DB read failed: #{Exception.message(e)}"}]}
  end

  def call(name, _args) when is_binary(name) do
    {:tool_error, [%{"type" => "text", "text" => "Unknown tool: #{name}"}]}
  end

  def call(_, _), do: {:tool_error, [%{"type" => "text", "text" => "Invalid tool name"}]}

  # --- get_command_result internals ---

  defp do_get_command_result(command_id, wait_seconds) do
    case safe_get_command(command_id) do
      {:error, msg} ->
        {:tool_error, [%{"type" => "text", "text" => msg}]}

      {:ok, nil} ->
        {:tool_error, [%{"type" => "text", "text" => not_found_message(command_id)}]}

      {:ok, row} ->
        cond do
          terminal?(row.status) ->
            render_terminal(row)

          wait_seconds == 0 ->
            render_running(row)

          true ->
            wait_for_terminal(command_id, wait_seconds, row)
        end
    end
  end

  defp wait_for_terminal(command_id, wait_seconds, fallback_row) do
    :ok = Subscribers.subscribe(command_id)

    # Re-query to close the race where the result arrived between the
    # initial lookup and the subscribe (write-then-broadcast ordering on
    # the publisher side means a row that's now terminal is authoritative).
    case safe_get_command(command_id) do
      {:ok, %{status: status} = row}
      when status in @terminal_statuses ->
        render_terminal(row)

      _ ->
        deadline_ms = wait_seconds * 1_000

        receive do
          {:command_done, ^command_id} ->
            case safe_get_command(command_id) do
              {:ok, %{} = row} -> dispatch_render(row)
              _ -> render_running(fallback_row)
            end
        after
          deadline_ms ->
            case safe_get_command(command_id) do
              {:ok, %{} = row} -> dispatch_render(row)
              _ -> render_running(fallback_row)
            end
        end
    end
  end

  defp dispatch_render(row) do
    if terminal?(row.status), do: render_terminal(row), else: render_running(row)
  end

  defp safe_get_command(command_id) do
    {:ok, Queries.get_command_by_id(command_id)}
  rescue
    e ->
      {:error, "Audit DB read failed: #{Exception.message(e)}"}
  end

  defp not_found_message(command_id) do
    "No command found with id '#{command_id}'. Use list_commands to find recent commands."
  end

  defp terminal?(status), do: status in @terminal_statuses

  # --- Header block rendering ---

  defp render_start_header(command_id, machine, started_at, command, timeout, opts) do
    clamped_from_above? = Keyword.get(opts, :clamped_from_above?, false)

    base =
      [
        "command_id: #{command_id}",
        "status: running",
        "machine: #{machine}",
        "started_at: #{format_ts(started_at)}",
        "command: #{render_command_for_header(command)}",
        "timeout: #{timeout}s"
      ]
      |> Enum.join("\n")

    text = base <> "\n"

    if clamped_from_above? do
      text <>
        "\n(timeout was clamped to the maximum of #{@max_async_timeout} seconds.)"
    else
      text
    end
  end

  defp render_running(row) do
    elapsed = DateTime.diff(DateTime.utc_now(), row.started_at, :second)

    text =
      [
        "status: running",
        "command_id: #{row.id}",
        "machine: #{row.machine}",
        "command: #{render_command_for_header(row.command || "")}",
        "started_at: #{format_ts(row.started_at)}",
        "elapsed: #{elapsed}s",
        "(no output captured yet — partial output streaming is a future enhancement)"
      ]
      |> Enum.join("\n")

    {:ok, [%{"type" => "text", "text" => text}]}
  end

  defp render_terminal(row) do
    duration =
      case row.completed_at do
        %DateTime{} = c -> DateTime.diff(c, row.started_at, :second)
        _ -> 0
      end

    header =
      [
        "command_id: #{row.id}",
        "status: #{row.status}",
        "machine: #{row.machine}",
        "command: #{render_command_for_header(row.command || "")}",
        "started_at: #{format_ts(row.started_at)}",
        "duration: #{duration}s"
      ]
      |> Enum.join("\n")

    ctx = %{
      command: row.command,
      machine: row.machine,
      timeout: row.timeout,
      working_dir: row.working_dir,
      path: row.path
    }

    body =
      case ResultFormatter.format(
             {:ok,
              %{
                status: row.status,
                output: row.output,
                error: row.error,
                exit_code: row.exit_code
              }},
             ctx
           ) do
        {:ok, text} -> text
        {:error, text} -> text
      end

    text = header <> "\n\n" <> body
    {:ok, [%{"type" => "text", "text" => text}]}
  end

  defp render_command_for_header(""), do: ""

  defp render_command_for_header(cmd) when is_binary(cmd) do
    case String.split(cmd, "\n", parts: 2) do
      [_single] -> cmd
      [first, _rest] -> first <> "…"
    end
  end

  defp render_command_for_header(_), do: ""

  # --- list_commands rendering ---

  defp render_list([]), do: "No commands found."

  defp render_list(rows) do
    rows
    |> Enum.map(&render_list_row/1)
    |> Enum.join("\n")
  end

  defp render_list_row(row) do
    started = format_ts(row.started_at)
    machine = row.machine || ""
    status = String.pad_trailing(row.status || "", @status_column_width)
    id = row.id || ""
    command = truncate_command(row.command || "")

    "#{started}  #{machine}  #{status}  #{id}  #{command}"
  end

  defp truncate_command(""), do: ""

  defp truncate_command(cmd) when is_binary(cmd) do
    first_line = first_line(cmd)

    if String.length(first_line) > @list_command_truncate do
      String.slice(first_line, 0, @list_command_truncate) <> "…"
    else
      first_line
    end
  end

  defp first_line(nil), do: ""

  defp first_line(cmd) when is_binary(cmd) do
    case String.split(cmd, "\n", parts: 2) do
      [single] -> single
      [first, _rest] -> first
    end
  end

  # --- Validation ---

  defp validate_async_timeout(nil), do: {:ok, @default_async_timeout, false}
  defp validate_async_timeout(val) when is_integer(val) and val < 1, do: {:ok, 1, false}

  defp validate_async_timeout(val) when is_integer(val) and val > @max_async_timeout,
    do: {:ok, @max_async_timeout, true}

  defp validate_async_timeout(val) when is_integer(val), do: {:ok, val, false}

  defp validate_async_timeout(_),
    do:
      {:tool_error,
       [%{"type" => "text", "text" => "timeout must be an integer number of seconds"}]}

  defp validate_wait_seconds(nil), do: {:ok, 0}

  defp validate_wait_seconds(val) when is_integer(val) and val < 0,
    do: {:tool_error, [%{"type" => "text", "text" => "wait_seconds must be >= 0"}]}

  defp validate_wait_seconds(val) when is_integer(val) and val > @max_wait_seconds,
    do: {:ok, @max_wait_seconds}

  defp validate_wait_seconds(val) when is_integer(val), do: {:ok, val}

  defp validate_wait_seconds(_),
    do: {:tool_error, [%{"type" => "text", "text" => "wait_seconds must be an integer"}]}

  defp validate_status_filter(nil), do: {:ok, nil}

  defp validate_status_filter(val) when is_binary(val) do
    if val in @valid_statuses do
      {:ok, val}
    else
      {:tool_error,
       [
         %{
           "type" => "text",
           "text" =>
             "Invalid status filter '#{val}'. Valid values: #{Enum.join(@valid_statuses, ", ")}"
         }
       ]}
    end
  end

  defp validate_status_filter(_),
    do: {:tool_error, [%{"type" => "text", "text" => "status must be a string"}]}

  defp validate_since(nil), do: {:ok, nil}

  defp validate_since(val) when is_binary(val) do
    case DateTime.from_iso8601(val) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> since_error()
    end
  end

  defp validate_since(_), do: since_error()

  defp since_error do
    {:tool_error,
     [
       %{
         "type" => "text",
         "text" =>
           "Invalid 'since' value — must be an ISO-8601 timestamp with offset or trailing Z."
       }
     ]}
  end

  defp validate_limit(nil), do: {:ok, 10}
  defp validate_limit(val) when is_integer(val) and val < 1, do: {:ok, 1}
  defp validate_limit(val) when is_integer(val) and val > 50, do: {:ok, 50}
  defp validate_limit(val) when is_integer(val), do: {:ok, val}

  defp validate_limit(_),
    do: {:tool_error, [%{"type" => "text", "text" => "limit must be an integer"}]}

  defp validate_optional_string(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      val when is_binary(val) and val != "" -> {:ok, val}
      "" -> {:tool_error, [%{"type" => "text", "text" => "#{key} cannot be empty"}]}
      _ -> {:tool_error, [%{"type" => "text", "text" => "#{key} must be a string"}]}
    end
  end

  defp reject_unknown_keys(args, allowed) when is_map(args) do
    case Enum.find(Map.keys(args), fn k -> k not in allowed end) do
      nil -> :ok
      bad -> {:tool_error, [%{"type" => "text", "text" => "Unknown argument: #{bad}"}]}
    end
  end

  defp reject_unknown_keys(_args, _allowed), do: :ok

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  # --- Helpers ---

  defp format_ts(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_ts(_), do: ""

  defp shape_text(dispatch_result, ctx) do
    case ResultFormatter.format(dispatch_result, ctx) do
      {:ok, text} -> {:ok, [%{"type" => "text", "text" => text}]}
      {:error, text} -> {:tool_error, [%{"type" => "text", "text" => text}]}
    end
  end

  # Empty `path` and `content` go to the agent (it owns validation), but
  # empty `machine` and `command` can't possibly be valid for the sync
  # path — reject early rather than dispatching a doomed call. The async
  # `start_command` opts in to allow_empty: true for `command` per
  # SPEC-10 §start_command edge cases.
  defp require_string(args, key, opts \\ []) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    case Map.get(args, key) do
      val when is_binary(val) and val != "" ->
        {:ok, val}

      "" when allow_empty ->
        {:ok, ""}

      "" ->
        {:tool_error, [%{"type" => "text", "text" => "#{key} is required and cannot be empty"}]}

      nil ->
        {:tool_error, [%{"type" => "text", "text" => "#{key} is required"}]}

      _ ->
        {:tool_error, [%{"type" => "text", "text" => "#{key} must be a string"}]}
    end
  end

  defp clamp_timeout(nil), do: @default_timeout
  defp clamp_timeout(val) when is_integer(val) and val < 1, do: 1

  defp clamp_timeout(val) when is_integer(val) and val > @max_shell_timeout,
    do: @max_shell_timeout

  defp clamp_timeout(val) when is_integer(val), do: val
  defp clamp_timeout(_), do: @default_timeout
end

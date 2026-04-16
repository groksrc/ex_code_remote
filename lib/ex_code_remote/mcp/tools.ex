defmodule ExCodeRemote.MCP.Tools do
  @moduledoc """
  MCP tool surface: definitions, validation, and dispatch.

  Tools are stateless module functions. Dispatch goes through
  `ExCodeRemote.Agent.dispatch/3`, which holds the request open until the
  agent replies or the timeout fires (60s default plus 5s slack inside the
  dispatcher). The HTTP plug runs each request in its own Cowboy process,
  so a slow tool blocks only its own request, never the server.
  """

  alias ExCodeRemote.Agent
  alias ExCodeRemote.MCP.ResultFormatter

  # Match the Python server: same 60s default for every tool. The MCP client
  # can override per-call for run_shell_command via the `timeout` argument.
  @default_timeout 60

  @machine_description "Target machine name (e.g. 'my-laptop', 'office-mac')"

  @tools [
    %{
      "name" => "run_shell_command",
      "description" =>
        "Execute a shell command on a remote machine. Use this to run any terminal command.",
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
            "description" => "Command timeout in seconds (default 60)",
            "default" => 60
          }
        },
        "required" => ["machine", "command"]
      }
    },
    %{
      "name" => "read_file",
      "description" => "Read the contents of a file on a remote machine.",
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
        "Write content to a file on a remote machine. Creates parent directories if needed.",
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
      "description" => "List contents of a directory on a remote machine.",
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

  def call(name, _args) when is_binary(name) do
    {:tool_error, [%{"type" => "text", "text" => "Unknown tool: #{name}"}]}
  end

  def call(_, _), do: {:tool_error, [%{"type" => "text", "text" => "Invalid tool name"}]}

  # --- Helpers ---

  defp shape_text(dispatch_result, ctx) do
    case ResultFormatter.format(dispatch_result, ctx) do
      {:ok, text} -> {:ok, [%{"type" => "text", "text" => text}]}
      {:error, text} -> {:tool_error, [%{"type" => "text", "text" => text}]}
    end
  end

  # Empty `path` and `content` go to the agent (it owns validation), but
  # empty `machine` and `command` can't possibly be valid — reject early
  # rather than dispatching a doomed call.
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
  defp clamp_timeout(val) when is_integer(val), do: val
  defp clamp_timeout(_), do: @default_timeout
end

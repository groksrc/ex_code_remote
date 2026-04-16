defmodule ExCodeRemote.MCP.Server do
  @moduledoc """
  ExMCP server exposing tools to AI clients.

  Defines five tools matching the Python server's MCP interface:
  run_shell_command, read_file, write_file, list_directory, check_agent_status.

  Tool handlers delegate to Agent.dispatch/3 for command execution and
  use ResultFormatter for output shaping.

  ExMCP's HttpPlug serializes tool calls through its session handler process.
  This means concurrent MCP clients' tool calls queue behind each other.
  Acceptable for initial deployment but worth revisiting if multiple
  Claude.ai sessions use the server simultaneously.
  """

  use ExMCP.Server.Handler

  alias ExCodeRemote.Agent
  alias ExCodeRemote.MCP.ResultFormatter

  # ExMCP 0.9.1 has two bugs in the initialize path:
  #   1. MessageProcessor.MethodHandlers.handle_initialize/6 sends
  #      {:handle_initialize, params}, but Server.Handler.__using__ only
  #      handles {:initialize, params}.
  #   2. Even if you reach the macro's clause, it replies {:ok, result}
  #      (2-tuple), but MessageProcessor expects {:ok, result, _state}
  #      (3-tuple), causing a CaseClauseError.
  # Override handle_call/3 to dispatch handle_initialize/2 ourselves with the
  # tuple shape MessageProcessor expects. We can't use plain `def` to add a
  # clause because `use GenServer` (inside ExMCP.Server.Handler) calls
  # `defoverridable handle_call: 3`, so the macro's first def after that
  # replaces prior clauses, and a clause after `use` is shadowed by the
  # macro's catch-all. Re-defoverridable + super gives us the override.
  defoverridable handle_call: 3

  def handle_call({:handle_initialize, params}, _from, state) do
    {:ok, result, new_state} = handle_initialize(params, state)
    {:reply, {:ok, result, new_state}, new_state}
  end

  def handle_call(msg, from, state), do: super(msg, from, state)

  # Supervisor entry point. The supervised instance is mostly a no-op at
  # runtime (ExMCP.MessageProcessor spawns its own per-request handler via
  # GenServer.start_link/2 without :name), but starting it on boot ensures
  # the module is loaded so detect_server_type/1 picks the :handler path.
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @default_timeout 60

  # --- Initialize ---

  @impl true
  def handle_initialize(_params, state) do
    {:ok,
     %{
       protocolVersion: "2025-03-26",
       serverInfo: %{
         name: "code-remote",
         version: Application.spec(:ex_code_remote, :vsn) |> to_string()
       },
       capabilities: %{
         tools: %{}
       }
     }, state}
  end

  # --- Tool Listing ---

  @impl true
  def handle_list_tools(_cursor, state) do
    tools = [
      %{
        name: "run_shell_command",
        description:
          "Execute a shell command on a remote machine. Use this to run any terminal command.",
        inputSchema: %{
          type: "object",
          properties: %{
            machine: %{
              type: "string",
              description: "Target machine name (e.g. 'my-laptop', 'office-mac')"
            },
            command: %{
              type: "string",
              description: "The shell command to execute"
            },
            working_dir: %{
              type: "string",
              description:
                "Optional working directory (defaults to home). Use ~ for home directory."
            },
            timeout: %{
              type: "integer",
              description: "Command timeout in seconds (default 60)",
              default: 60
            }
          },
          required: ["machine", "command"]
        }
      },
      %{
        name: "read_file",
        description: "Read the contents of a file on a remote machine.",
        inputSchema: %{
          type: "object",
          properties: %{
            machine: %{
              type: "string",
              description: "Target machine name (e.g. 'my-laptop', 'office-mac')"
            },
            path: %{
              type: "string",
              description: "Path to the file. Use ~ for home directory."
            }
          },
          required: ["machine", "path"]
        }
      },
      %{
        name: "write_file",
        description:
          "Write content to a file on a remote machine. Creates parent directories if needed.",
        inputSchema: %{
          type: "object",
          properties: %{
            machine: %{
              type: "string",
              description: "Target machine name (e.g. 'my-laptop', 'office-mac')"
            },
            path: %{
              type: "string",
              description: "Path to the file. Use ~ for home directory."
            },
            content: %{
              type: "string",
              description: "Content to write to the file"
            }
          },
          required: ["machine", "path", "content"]
        }
      },
      %{
        name: "list_directory",
        description: "List contents of a directory on a remote machine.",
        inputSchema: %{
          type: "object",
          properties: %{
            machine: %{
              type: "string",
              description: "Target machine name (e.g. 'my-laptop', 'office-mac')"
            },
            path: %{
              type: "string",
              description: "Path to the directory. Use ~ for home directory."
            }
          },
          required: ["machine", "path"]
        }
      },
      %{
        name: "check_agent_status",
        description: "Check which machines are connected and ready to receive commands.",
        inputSchema: %{
          type: "object",
          properties: %{}
        }
      }
    ]

    {:ok, tools, state}
  end

  # --- Tool Handlers ---

  @impl true
  def handle_call_tool("run_shell_command", args, state) do
    with {:ok, machine} <- validate_required_string(args, "machine"),
         {:ok, command} <- validate_required_string(args, "command") do
      timeout = clamp_timeout(args["timeout"])

      result =
        Agent.dispatch(machine, %{
          type: :shell,
          command: command,
          working_dir: args["working_dir"],
          timeout: timeout
        })

      tool_result(result, state)
    else
      {:error, message} -> tool_error(message, state)
    end
  end

  def handle_call_tool("read_file", args, state) do
    with {:ok, machine} <- validate_required_string(args, "machine"),
         {:ok, path} <- validate_required_string(args, "path") do
      result = Agent.dispatch(machine, %{type: :read_file, path: path})
      tool_result(result, state)
    else
      {:error, message} -> tool_error(message, state)
    end
  end

  def handle_call_tool("write_file", args, state) do
    with {:ok, machine} <- validate_required_string(args, "machine"),
         {:ok, path} <- validate_required_string(args, "path"),
         {:ok, content} <- validate_required_string(args, "content") do
      result = Agent.dispatch(machine, %{type: :write_file, path: path, content: content})
      tool_result(result, state)
    else
      {:error, message} -> tool_error(message, state)
    end
  end

  def handle_call_tool("list_directory", args, state) do
    with {:ok, machine} <- validate_required_string(args, "machine"),
         {:ok, path} <- validate_required_string(args, "path") do
      result = Agent.dispatch(machine, %{type: :list_dir, path: path})
      tool_result(result, state)
    else
      {:error, message} -> tool_error(message, state)
    end
  end

  def handle_call_tool("check_agent_status", _args, state) do
    case Agent.list() do
      [] ->
        {:ok, [%{type: "text", text: "No agents are connected."}], state}

      machines ->
        {:ok, [%{type: "text", text: Enum.join(machines, ", ")}], state}
    end
  end

  def handle_call_tool(name, _args, state) do
    tool_error("Unknown tool: #{name}", state)
  end

  # --- Helpers ---

  defp validate_required_string(args, field) do
    case args[field] do
      val when is_binary(val) and val != "" -> {:ok, val}
      "" -> {:error, "#{field} is required and cannot be empty"}
      nil -> {:error, "#{field} is required"}
      _ -> {:error, "#{field} must be a string"}
    end
  end

  defp clamp_timeout(nil), do: @default_timeout
  defp clamp_timeout(val) when is_integer(val) and val < 1, do: 1
  defp clamp_timeout(val) when is_integer(val), do: val
  defp clamp_timeout(_), do: @default_timeout

  defp tool_result(dispatch_result, state) do
    case ResultFormatter.format(dispatch_result) do
      {:ok, text} ->
        {:ok, [%{type: "text", text: text}], state}

      {:error, text} ->
        {:ok, %{content: [%{type: "text", text: text}], isError: true}, state}
    end
  end

  defp tool_error(message, state) do
    {:ok, %{content: [%{type: "text", text: message}], isError: true}, state}
  end
end

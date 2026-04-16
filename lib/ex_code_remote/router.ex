defmodule ExCodeRemote.Router do
  use Plug.Router
  use Plug.ErrorHandler
  import Ecto.Query

  plug(ExCodeRemote.Plugs.RequestTiming)
  plug(:match)
  plug(:maybe_parse_body)
  plug(:dispatch)

  # Skip Plug.Parsers for /mcp routes — the MCP plug reads and decodes the
  # body itself. Plug.Parsers consumes the request body, leaving nothing
  # for the downstream plug to read.
  defp maybe_parse_body(%{path_info: ["mcp" | _]} = conn, _opts), do: conn

  defp maybe_parse_body(conn, _opts) do
    Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
  end

  get "/health" do
    body =
      Jason.encode!(%{
        status: "ok",
        version: Application.spec(:ex_code_remote, :vsn) |> to_string(),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  get "/ws/agent" do
    conn = ExCodeRemote.Plugs.PrivateNetwork.call(conn, [])

    if conn.halted do
      conn
    else
      token = conn.query_params["token"]
      machine = conn.query_params["machine"]
      expected_token = Application.get_env(:ex_code_remote, :auth_token)

      cond do
        is_nil(expected_token) or is_nil(token) or token == "" or
            not Plug.Crypto.secure_compare(token, expected_token) ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(403, Jason.encode!(%{error: "forbidden"}))

        is_nil(machine) or machine == "" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(%{error: "missing_machine"}))

        true ->
          conn
          |> WebSockAdapter.upgrade(ExCodeRemote.Agent.Socket, machine, [])
      end
    end
  end

  get "/commands" do
    handle_commands(conn)
  end

  # MCP transport — our own JSON-RPC over HTTP plug. Replaces ExMCP.HttpPlug
  # so we control the request timeout (ExMCP hardcoded 10s, capping every
  # tool call). The plug accepts POST at any path under /mcp, so existing
  # Claude.ai connectors configured for /mcp/sse keep working.
  forward("/mcp", to: ExCodeRemote.MCP.Plug)

  match _ do
    body = Jason.encode!(%{error: "not found"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, body)
  end

  defp handle_commands(conn) do
    expected_token = Application.get_env(:ex_code_remote, :auth_token)

    auth =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] when is_binary(expected_token) ->
          if Plug.Crypto.secure_compare(token, expected_token), do: :ok, else: :error

        _ ->
          :error
      end

    case auth do
      :ok ->
        conn = fetch_query_params(conn)

        limit =
          case Integer.parse(conn.query_params["limit"] || "") do
            {n, ""} when n > 0 -> min(n, 100)
            _ -> 20
          end

        machine = conn.query_params["machine"]

        query =
          ExCodeRemote.Audit.Command
          |> order_by([c], desc: c.started_at)
          |> limit(^limit)

        query =
          if machine && machine != "",
            do: where(query, [c], c.machine == ^machine),
            else: query

        commands =
          ExCodeRemote.Audit.Repo.all(query)
          |> Enum.map(&serialize_command/1)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{commands: commands}))

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    end
  rescue
    _ ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, Jason.encode!(%{error: "audit system unavailable"}))
  end

  defp serialize_command(%ExCodeRemote.Audit.Command{} = cmd) do
    %{
      id: cmd.id,
      machine: cmd.machine,
      type: cmd.type,
      status: cmd.status,
      command: cmd.command,
      path: cmd.path,
      working_dir: cmd.working_dir,
      timeout: cmd.timeout,
      output: cmd.output,
      error: cmd.error,
      exit_code: cmd.exit_code,
      duration_ms: cmd.duration_ms,
      started_at: cmd.started_at && DateTime.to_iso8601(cmd.started_at),
      completed_at: cmd.completed_at && DateTime.to_iso8601(cmd.completed_at)
    }
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, _assigns) do
    body = Jason.encode!(%{error: "internal server error"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(500, body)
  end
end

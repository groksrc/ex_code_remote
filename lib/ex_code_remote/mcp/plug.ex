defmodule ExCodeRemote.MCP.Plug do
  @moduledoc """
  MCP transport over HTTP, hand-rolled to replace `ExMCP.HttpPlug`.

  Speaks just enough of MCP's "streamable HTTP" transport for Claude.ai's
  connector and any other MCP client that POSTs JSON-RPC and reads the
  response synchronously from the body. No SSE — `GET` returns 405 so MCP
  clients know not to attempt one (per spec).

  Why hand-roll: ExMCP 0.9.1's `MessageProcessor` hardcodes a 10-second
  `GenServer.call` timeout for `tools/call`, which silently caps every
  shell command at 10 seconds regardless of the agent's own timeout. Owning
  the request path lets us hold the connection open for the full dispatch
  budget (default 60s + 5s slack from `Commands.Dispatcher`).

  Each request runs in its own Cowboy process, so a slow tool blocks only
  itself. There's no shared mutable state between requests.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  alias ExCodeRemote.MCP.Tools

  # JSON-RPC 2.0 error codes (https://www.jsonrpc.org/specification#error_object)
  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @internal_error -32603

  # Latest MCP version this server implements. We echo back the client's
  # requested version when they negotiate a different supported one — most
  # clients are happy with that.
  @protocol_version "2025-11-25"

  # Cap request bodies at 10MB. Plenty of headroom for write_file with
  # large content, but keeps a misbehaving client from exhausting memory.
  @max_body_bytes 10_000_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, _opts), do: handle_post(conn)

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn |> put_cors_headers() |> send_resp(204, "")
  end

  def call(%Plug.Conn{method: "DELETE"} = conn, _opts) do
    # MCP allows DELETE for session termination. We don't track sessions,
    # so just acknowledge and move on.
    conn |> put_cors_headers() |> send_resp(204, "")
  end

  def call(%Plug.Conn{method: "GET"} = conn, _opts), do: send_method_not_allowed(conn)
  def call(conn, _opts), do: send_method_not_allowed(conn)

  # --- POST handling ---

  defp handle_post(conn) do
    with {:ok, body, conn} <- read_request_body(conn),
         {:ok, request} <- Jason.decode(body) do
      route(conn, request)
    else
      {:error, :body_too_large, conn} ->
        send_json_error(
          conn,
          413,
          nil,
          @invalid_request,
          "Request body exceeds #{@max_body_bytes} bytes"
        )

      {:error, %Jason.DecodeError{}} ->
        send_json_error(conn, 400, nil, @parse_error, "Parse error")

      {:error, reason} ->
        Logger.warning("MCP read_body failed: #{inspect(reason)}")
        send_json_error(conn, 400, nil, @invalid_request, "Could not read request body")
    end
  rescue
    exception ->
      Logger.error(
        "MCP plug crashed: #{Exception.message(exception)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      send_json_error(conn, 500, nil, @internal_error, "Internal server error")
  end

  defp route(conn, requests) when is_list(requests) do
    # JSON-RPC batches are optional in MCP transports and Claude.ai doesn't
    # use them. Reject explicitly with a clear error rather than half-implement.
    send_json_error(conn, 400, nil, @invalid_request, "Batch requests are not supported")
  end

  defp route(conn, %{"method" => method} = request) do
    id = Map.get(request, "id")
    params = Map.get(request, "params", %{})

    if is_nil(id) do
      # Notification — no response body, just acknowledge per JSON-RPC.
      handle_notification(method, params)
      conn |> put_cors_headers() |> send_resp(202, "")
    else
      response = handle_request(method, id, params)
      send_json(conn, 200, response)
    end
  end

  defp route(conn, _) do
    send_json_error(conn, 400, nil, @invalid_request, "Invalid Request")
  end

  # --- Method dispatch ---

  defp handle_request("initialize", id, params) do
    proto = negotiate_protocol(Map.get(params, "protocolVersion"))

    success(id, %{
      "protocolVersion" => proto,
      "serverInfo" => %{"name" => "code-remote", "version" => version()},
      "capabilities" => %{"tools" => %{}}
    })
  end

  defp handle_request("ping", id, _params), do: success(id, %{})

  defp handle_request("tools/list", id, _params) do
    success(id, %{"tools" => Tools.all()})
  end

  defp handle_request("tools/call", id, params) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{}) || %{}

    case Tools.call(name, arguments) do
      {:ok, content} ->
        success(id, %{"content" => content})

      {:tool_error, content} ->
        success(id, %{"content" => content, "isError" => true})
    end
  end

  defp handle_request(method, id, _params) do
    error_response(id, @method_not_found, "Method not found: #{method}")
  end

  defp handle_notification(_method, _params), do: :ok

  # --- Response builders ---

  defp success(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp send_json(conn, status, body) do
    conn
    |> put_cors_headers()
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_json_error(conn, status, id, code, message) do
    send_json(conn, status, error_response(id, code, message))
  end

  defp send_method_not_allowed(conn) do
    conn
    |> put_cors_headers()
    |> put_resp_header("allow", "POST, OPTIONS, DELETE")
    |> send_resp(405, "")
  end

  defp put_cors_headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "POST, OPTIONS, DELETE")
    |> put_resp_header(
      "access-control-allow-headers",
      "content-type, authorization, mcp-protocol-version, mcp-session-id"
    )
    |> put_resp_header("access-control-max-age", "86400")
  end

  # --- Body reading with size cap ---

  defp read_request_body(conn) do
    case read_body(conn, length: @max_body_bytes, read_length: @max_body_bytes) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :body_too_large, conn}
      {:error, _} = err -> err
    end
  end

  # --- Misc ---

  defp negotiate_protocol(nil), do: @protocol_version
  defp negotiate_protocol(version) when is_binary(version), do: version
  defp negotiate_protocol(_), do: @protocol_version

  defp version do
    Application.spec(:ex_code_remote, :vsn) |> to_string()
  end
end

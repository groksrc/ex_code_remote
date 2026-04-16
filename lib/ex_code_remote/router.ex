defmodule ExCodeRemote.Router do
  use Plug.Router
  use Plug.ErrorHandler

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

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

  match _ do
    body = Jason.encode!(%{error: "not found"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, body)
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, _assigns) do
    body = Jason.encode!(%{error: "internal server error"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(500, body)
  end
end

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

defmodule ExCodeRemote.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @opts ExCodeRemote.Router.init([])

  test "GET /health returns 200 with JSON status" do
    conn = conn(:get, "/health") |> ExCodeRemote.Router.call(@opts)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"

    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ok"
    assert is_binary(body["version"])
    assert is_binary(body["timestamp"])
    assert String.ends_with?(body["timestamp"], "Z")
  end

  test "GET /health version matches mix.exs" do
    conn = conn(:get, "/health") |> ExCodeRemote.Router.call(@opts)
    body = Jason.decode!(conn.resp_body)
    assert body["version"] == Application.spec(:ex_code_remote, :vsn) |> to_string()
  end

  test "unknown route returns 404 JSON" do
    conn = conn(:get, "/nonexistent") |> ExCodeRemote.Router.call(@opts)

    assert conn.status == 404
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"

    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "not found"
  end

  test "POST to unknown route returns 404 JSON" do
    conn = conn(:post, "/whatever") |> ExCodeRemote.Router.call(@opts)

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "not found"
  end
end

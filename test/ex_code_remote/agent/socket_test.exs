defmodule ExCodeRemote.Agent.SocketTest do
  use ExUnit.Case, async: false

  alias ExCodeRemote.Test.WSClient

  @token "test-token-for-testing"

  setup do
    {:ok, server} =
      Bandit.start_link(plug: ExCodeRemote.Router, port: 0, scheme: :http)

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      Process.exit(server, :kill)
    end)

    {:ok, port: port}
  end

  test "successful connect and disconnect", %{port: port} do
    machine = "ws-test-#{System.unique_integer([:positive])}"
    {:ok, state} = WSClient.connect(port, token: @token, machine: machine)

    assert ExCodeRemote.Agent.connected?(machine)

    {:ok, _state} = WSClient.send_close(state)
    Process.sleep(200)
    refute ExCodeRemote.Agent.connected?(machine)
  end

  test "bad token returns 403", %{port: port} do
    assert {:error, 403, body} =
             WSClient.connect(port, token: "wrong-token", machine: "rejected")

    assert %{"error" => "forbidden"} = Jason.decode!(body)
  end

  test "missing token returns 403", %{port: port} do
    assert {:error, 403, _body} =
             WSClient.connect(port, token: "", machine: "rejected")
  end

  test "missing machine returns 400", %{port: port} do
    assert {:error, 400, body} =
             WSClient.connect(port, token: @token, machine: "")

    assert %{"error" => "missing_machine"} = Jason.decode!(body)
  end

  test "ping/pong round-trip", %{port: port} do
    machine = "ping-test-#{System.unique_integer([:positive])}"
    {:ok, state} = WSClient.connect(port, token: @token, machine: machine)

    {:ok, state} = WSClient.send_json(state, %{type: "ping"})
    {:ok, frame, _state} = WSClient.receive_frame(state)

    assert frame["type"] == "pong"
  end

  test "malformed JSON does not kill the connection", %{port: port} do
    machine = "malformed-test-#{System.unique_integer([:positive])}"
    {:ok, state} = WSClient.connect(port, token: @token, machine: machine)

    {:ok, state} = WSClient.send_text(state, "this is not json{{{")
    # Connection should still work
    {:ok, state} = WSClient.send_json(state, %{type: "ping"})
    {:ok, frame, _state} = WSClient.receive_frame(state)

    assert frame["type"] == "pong"
  end

  test "unknown frame type is silently ignored", %{port: port} do
    machine = "unknown-type-#{System.unique_integer([:positive])}"
    {:ok, state} = WSClient.connect(port, token: @token, machine: machine)

    {:ok, state} = WSClient.send_json(state, %{type: "some_future_type", data: "whatever"})
    {:ok, state} = WSClient.send_json(state, %{type: "ping"})
    {:ok, frame, _state} = WSClient.receive_frame(state)

    assert frame["type"] == "pong"
  end

  test "binary frame closes connection with 1003", %{port: port} do
    machine = "binary-test-#{System.unique_integer([:positive])}"
    {:ok, state} = WSClient.connect(port, token: @token, machine: machine)

    {:ok, state} = WSClient.send_binary(state, <<1, 2, 3>>)
    {:close, 1003, _reason, _state} = WSClient.receive_frame(state)
  end

  test "reconnect replaces old connection", %{port: port} do
    machine = "reconnect-test-#{System.unique_integer([:positive])}"

    {:ok, _state1} = WSClient.connect(port, token: @token, machine: machine)
    assert ExCodeRemote.Agent.connected?(machine)

    # Second connection with same machine name
    {:ok, _state2} = WSClient.connect(port, token: @token, machine: machine)
    Process.sleep(100)

    assert ExCodeRemote.Agent.connected?(machine)
    assert length(ExCodeRemote.Agent.list() |> Enum.filter(&(&1 == machine))) == 1
  end
end

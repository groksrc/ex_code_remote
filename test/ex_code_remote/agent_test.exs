defmodule ExCodeRemote.AgentTest do
  use ExUnit.Case, async: true

  alias ExCodeRemote.Agent

  test "connected? returns false for unknown machine" do
    refute Agent.connected?("no-such-machine")
  end

  test "list returns a list" do
    machines = Agent.list()
    assert is_list(machines)
  end

  test "dispatch returns {:error, :not_connected} for unknown machine" do
    assert {:error, :not_connected} = Agent.dispatch("no-such-machine", %{type: :shell}, 5000)
  end

  test "dispatch returns {:error, :not_connected} when connection dies between lookup and call" do
    machine = "race-test-#{System.unique_integer([:positive])}"
    dummy_socket = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, pid} = Agent.start_connection(machine, dummy_socket)
    assert Agent.connected?(machine)

    Process.exit(pid, :kill)
    Process.sleep(50)

    assert {:error, :not_connected} = Agent.dispatch(machine, %{type: :shell}, 5000)
  end

  test "stop_connection returns {:error, :not_connected} for unknown machine" do
    assert {:error, :not_connected} = Agent.stop_connection("no-such-machine")
  end

  test "stop_connection stops an existing connection" do
    machine = "stop-test-#{System.unique_integer([:positive])}"
    dummy_socket = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, _pid} = Agent.start_connection(machine, dummy_socket)
    assert Agent.connected?(machine)

    assert {:ok, :stopped} = Agent.stop_connection(machine)
    Process.sleep(50)
    refute Agent.connected?(machine)
  end
end

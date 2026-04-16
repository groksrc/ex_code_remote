defmodule ExCodeRemote.Agent.ConnectionTest do
  use ExUnit.Case, async: true

  alias ExCodeRemote.Agent.Connection

  setup do
    machine = "test-#{System.unique_integer([:positive])}"
    {:ok, machine: machine}
  end

  defp start_connection(machine) do
    dummy_socket = spawn(fn -> Process.sleep(:infinity) end)

    pid =
      start_supervised!(%{
        id: machine,
        start: {Connection, :start_link, [{machine, dummy_socket}]},
        restart: :temporary
      })

    {pid, dummy_socket}
  end

  test "starts and registers under machine name", %{machine: machine} do
    {pid, _socket} = start_connection(machine)
    assert [{^pid, _}] = Registry.lookup(ExCodeRemote.AgentRegistry, machine)
  end

  test "deregisters when stopped", %{machine: machine} do
    {pid, _socket} = start_connection(machine)
    assert Process.alive?(pid)

    GenServer.stop(pid)
    Process.sleep(50)
    assert [] = Registry.lookup(ExCodeRemote.AgentRegistry, machine)
  end

  test "terminates when monitored socket dies", %{machine: machine} do
    {pid, socket} = start_connection(machine)
    ref = Process.monitor(pid)

    Process.exit(socket, :kill)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    Process.sleep(50)
    assert [] = Registry.lookup(ExCodeRemote.AgentRegistry, machine)
  end

  test "handle_result with unknown id is a no-op", %{machine: machine} do
    {pid, _socket} = start_connection(machine)

    Connection.handle_result(pid, %{"id" => "unknown", "status" => "completed"})
    assert Process.alive?(pid)
  end

  test "dispatch returns {:error, :not_implemented}", %{machine: machine} do
    {pid, _socket} = start_connection(machine)
    assert {:error, :not_implemented} = GenServer.call(pid, {:dispatch, %{type: :shell}})
  end

  test "initial state has empty pending map and connected_at", %{machine: machine} do
    {pid, _socket} = start_connection(machine)

    state = :sys.get_state(pid)
    assert state.pending == %{}
    assert %DateTime{} = state.connected_at
    assert state.machine == machine
  end
end

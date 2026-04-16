defmodule ExCodeRemote.Agent.ConnectionTest do
  use ExUnit.Case, async: true

  alias ExCodeRemote.Agent.Connection

  setup do
    machine = "test-#{System.unique_integer([:positive])}"
    {:ok, machine: machine}
  end

  defp start_connection(machine) do
    dummy_socket =
      spawn(fn ->
        receive do
          _ -> :ok
        end
      end)

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

  test "initial state has empty pending map and connected_at", %{machine: machine} do
    {pid, _socket} = start_connection(machine)

    state = :sys.get_state(pid)
    assert state.pending == %{}
    assert %DateTime{} = state.connected_at
    assert state.machine == machine
  end

  test "terminate replies to all pending callers with :agent_disconnected", %{machine: machine} do
    # Use a socket that stays alive and accepts :send_frame messages
    socket =
      spawn(fn ->
        receive_loop = fn loop ->
          receive do
            _ -> loop.(loop)
          end
        end

        receive_loop.(receive_loop)
      end)

    pid =
      start_supervised!(%{
        id: machine,
        start: {Connection, :start_link, [{machine, socket}]},
        restart: :temporary
      })

    # Spawn callers that will block on dispatch
    tasks =
      for i <- 1..3 do
        Task.async(fn ->
          GenServer.call(
            pid,
            {:dispatch, "cmd-#{i}", %{type: :shell, command: "echo", timeout: 30}},
            10_000
          )
        end)
      end

    # Wait for all calls to be in the pending map
    Process.sleep(100)

    # Verify they're pending
    state = :sys.get_state(pid)
    assert map_size(state.pending) == 3

    # Stop the connection
    GenServer.stop(pid, :shutdown)

    results = Task.await_many(tasks, 5000)

    for result <- results do
      assert {:error, :agent_disconnected} = result
    end
  end
end

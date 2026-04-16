defmodule ExCodeRemote.Commands.DispatcherAsyncTest do
  @moduledoc """
  Tests for the SPEC-10 Unit 1 async dispatch path:

      ExCodeRemote.Commands.Dispatcher.run_async/2

  and the agent connection's handling of async in-flight entries
  (write to audit DB, broadcast to subscribers, sweep on terminate).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import ExCodeRemote.Test.Helpers, only: [await_connected: 1]

  alias ExCodeRemote.Agent
  alias ExCodeRemote.Audit.{Command, Repo}
  alias ExCodeRemote.Commands.{Dispatcher, Subscribers}
  alias ExCodeRemote.Test.FakeAgent

  setup :setup_server
  defp setup_server(ctx), do: ExCodeRemote.Test.Helpers.setup_server(ctx)

  setup do
    Repo.delete_all(Command)
    :ok
  end

  defp wait_for_audit_status(command_id, expected_status, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll = fn poll ->
      case Repo.get(Command, command_id) do
        %Command{status: ^expected_status} = row ->
          {:ok, row}

        _ ->
          if System.monotonic_time(:millisecond) > deadline do
            row = Repo.get(Command, command_id)

            flunk(
              "Timed out waiting for #{command_id} to reach status=#{expected_status}; " <>
                "current row=#{inspect(row)}"
            )
          else
            Process.sleep(20)
            poll.(poll)
          end
      end
    end

    poll.(poll)
  end

  describe "run_async/2 — happy path" do
    test "async reply writes terminal audit row", %{port: port} do
      machine = "async-ok-#{System.unique_integer([:positive])}"

      handler = fn %{"id" => id} ->
        %{
          type: "result",
          id: id,
          status: "completed",
          output: "async-output",
          error: nil,
          exit_code: 0
        }
      end

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: handler, owner: self()},
          id: machine
        )

      await_connected(machine)

      assert {:ok, command_id, %DateTime{} = started_at} =
               Dispatcher.run_async(machine, %{type: :shell, command: "echo async", timeout: 5})

      assert is_binary(command_id)
      assert byte_size(command_id) == 16

      # Audit row exists and is initially "running" (the agent reply is async).
      # Wait for the terminal write.
      {:ok, row} = wait_for_audit_status(command_id, "completed")
      assert row.machine == machine
      assert row.command == "echo async"
      assert row.output == "async-output"
      assert row.exit_code == 0
      # started_at is truncated to seconds by run_async; the DB column is
      # utc_datetime_usec, so compare via DateTime.compare to ignore
      # microsecond padding.
      assert DateTime.compare(row.started_at, started_at) == :eq
      assert %DateTime{} = row.completed_at
      assert is_integer(row.duration_ms) and row.duration_ms >= 0
    end

    test "returns {:error, :not_connected} for unknown machine without inserting a row" do
      assert {:error, :not_connected} =
               Dispatcher.run_async("no-such-machine", %{type: :shell, command: "echo hi"})

      # No row was created (per SPEC-10 Decision 1).
      assert Repo.all(Command) == []
    end

    test "Agent.dispatch_async/2 facade: returns not_connected without DB write" do
      assert {:error, :not_connected} =
               Agent.dispatch_async("no-such", %{type: :shell, command: "echo hi"})

      assert Repo.all(Command) == []
    end
  end

  describe "sync + async coexist" do
    test "one sync and one async to the same connection both terminate correctly", %{port: port} do
      machine = "mixed-#{System.unique_integer([:positive])}"

      handler = fn %{"id" => id, "command" => cmd} ->
        %{
          type: "result",
          id: id,
          status: "completed",
          output: "out-for-#{cmd}",
          exit_code: 0
        }
      end

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: handler, owner: self()},
          id: machine
        )

      await_connected(machine)

      sync_task =
        Task.async(fn ->
          Dispatcher.run(machine, %{type: :shell, command: "sync-cmd", timeout: 5})
        end)

      assert {:ok, async_id, _started} =
               Dispatcher.run_async(machine, %{type: :shell, command: "async-cmd", timeout: 5})

      # Sync result via direct caller.
      assert {:ok, %{output: "out-for-sync-cmd"}} = Task.await(sync_task, 5_000)

      # Async result via audit DB.
      {:ok, row} = wait_for_audit_status(async_id, "completed")
      assert row.output == "out-for-async-cmd"
    end
  end

  describe "concurrent async dispatch" do
    test "many async commands dispatched rapidly all reach the audit DB", %{port: port} do
      machine = "concurrent-async-#{System.unique_integer([:positive])}"

      handler = fn %{"id" => id, "command" => cmd} ->
        %{
          type: "result",
          id: id,
          status: "completed",
          output: cmd,
          exit_code: 0
        }
      end

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: handler, owner: self()},
          id: machine
        )

      await_connected(machine)

      ids =
        for i <- 1..15 do
          {:ok, id, _started} =
            Dispatcher.run_async(machine, %{
              type: :shell,
              command: "cmd-#{i}",
              timeout: 5
            })

          {id, "cmd-#{i}"}
        end

      for {id, expected_cmd} <- ids do
        {:ok, row} = wait_for_audit_status(id, "completed", 5_000)
        assert row.output == expected_cmd
      end

      # All ids are unique.
      assert length(Enum.uniq(Enum.map(ids, &elem(&1, 0)))) == length(ids)
    end
  end

  describe "agent disconnect mid-async" do
    test "normal exit: in-flight async row transitions to agent_disconnected", %{port: port} do
      machine = "disco-normal-#{System.unique_integer([:positive])}"
      handler = fn _frame -> nil end

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: handler, owner: self()},
          id: machine
        )

      await_connected(machine)

      assert {:ok, command_id, _started} =
               Dispatcher.run_async(machine, %{type: :shell, command: "long", timeout: 30})

      # Stop the connection cleanly via the supervisor (normal exit).
      assert {:ok, :stopped} = Agent.stop_connection(machine)

      {:ok, row} = wait_for_audit_status(command_id, "agent_disconnected")
      assert %DateTime{} = row.completed_at
      assert is_integer(row.duration_ms) and row.duration_ms >= 0
    end

    test "raised-exception / abnormal exit: in-flight async row transitions to agent_disconnected",
         %{port: port} do
      machine = "disco-exception-#{System.unique_integer([:positive])}"
      handler = fn _frame -> nil end

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: handler, owner: self()},
          id: machine
        )

      await_connected(machine)

      assert {:ok, command_id, _started} =
               Dispatcher.run_async(machine, %{type: :shell, command: "long", timeout: 30})

      # Stop the connection with a non-:normal reason to exercise the
      # abnormal-exit path. GenServer.stop/3 causes terminate/2 to run
      # with the supplied reason; this is what happens when the
      # supervisor restarts the child due to a crash, or when a handler
      # raises and the process exits with the raised-exception reason.
      # (Brutal kill bypasses terminate/2 by design; that path is
      # exercised by the StartupSweeper test.)
      [{conn_pid, _}] = Registry.lookup(ExCodeRemote.AgentRegistry, machine)
      ref = Process.monitor(conn_pid)
      # Use catch to tolerate either a plain :ok return or an exit signal
      # (depending on how the GenServer returns from terminate/2).
      try do
        GenServer.stop(conn_pid, {:simulated, :crash}, 2_000)
      catch
        :exit, _ -> :ok
      end

      # Confirm the process actually died with an abnormal reason.
      assert_receive {:DOWN, ^ref, :process, ^conn_pid, reason}, 2_000
      refute reason == :normal

      {:ok, row} = wait_for_audit_status(command_id, "agent_disconnected")
      assert %DateTime{} = row.completed_at
    end
  end

  describe "subscribers broadcast on terminal" do
    test "subscriber receives {:command_done, command_id} when async result lands",
         %{port: port} do
      machine = "broadcast-#{System.unique_integer([:positive])}"

      # Slow handler so we can subscribe before the reply lands.
      handler = fn %{"id" => id} ->
        {:delay, 50, %{type: "result", id: id, status: "completed", output: "ok", exit_code: 0}}
      end

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: handler, owner: self()},
          id: machine
        )

      await_connected(machine)

      assert {:ok, command_id, _started} =
               Dispatcher.run_async(machine, %{type: :shell, command: "x", timeout: 5})

      # Subscribe BEFORE the reply lands.
      :ok = Subscribers.subscribe(command_id)

      assert_receive {:command_done, ^command_id}, 2_000
    end

    test "subscriber on a disconnect-swept async also receives broadcast",
         %{port: port} do
      machine = "broadcast-disco-#{System.unique_integer([:positive])}"
      handler = fn _frame -> nil end

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: handler, owner: self()},
          id: machine
        )

      await_connected(machine)

      assert {:ok, command_id, _started} =
               Dispatcher.run_async(machine, %{type: :shell, command: "long", timeout: 30})

      :ok = Subscribers.subscribe(command_id)

      # Force a normal terminate.
      assert {:ok, :stopped} = Agent.stop_connection(machine)

      assert_receive {:command_done, ^command_id}, 2_000
    end
  end

  describe "audit-DB write failure on async reply" do
    @doc """
    Deterministic failure mechanism: start an async command, stop the
    audit Repo, then inject a result frame for a DIFFERENT id (the
    late-reply path) so the write fails without interfering with
    in-flight commands that wouldn't have finished yet anyway. The
    late-reply path and the in-flight-reply path share the same
    write_terminal_row/broadcast helpers, so exercising one exercises
    the error-isolation branch for both.
    """
    test "connection stays alive, error logged, broadcast still fires", %{port: port} do
      machine = "audit-fail-#{System.unique_integer([:positive])}"

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, owner: self()},
          id: machine
        )

      await_connected(machine)

      [{conn_pid, _}] = Registry.lookup(ExCodeRemote.AgentRegistry, machine)
      assert Process.alive?(conn_pid)

      Supervisor.terminate_child(ExCodeRemote.Supervisor, ExCodeRemote.Audit.Repo)

      try do
        fake_id = "ZZZZZZZZZZZZZZZZ"
        :ok = Subscribers.subscribe(fake_id)

        log =
          capture_log(fn ->
            ExCodeRemote.Agent.Connection.handle_result(conn_pid, %{
              "id" => fake_id,
              "status" => "completed",
              "output" => "x",
              "exit_code" => 0
            })

            assert_receive {:command_done, ^fake_id}, 2_000
          end)

        assert log =~ "async_audit_write_failed"
        assert Process.alive?(conn_pid)
      after
        Supervisor.restart_child(ExCodeRemote.Supervisor, ExCodeRemote.Audit.Repo)
        Process.sleep(50)
      end
    end
  end
end

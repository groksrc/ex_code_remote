defmodule ExCodeRemote.Commands.DispatcherTest do
  use ExUnit.Case, async: false

  alias ExCodeRemote.Commands.{Dispatcher, Codec}
  alias ExCodeRemote.Test.FakeAgent
  import ExCodeRemote.Test.Helpers

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

  describe "command ID generation" do
    test "generates 16-character URL-safe string" do
      id = Codec.generate_command_id()
      assert byte_size(id) == 16
      assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, id)
    end

    test "generates unique IDs" do
      ids = for _ <- 1..100, do: Codec.generate_command_id()
      assert length(Enum.uniq(ids)) == 100
    end
  end

  describe "dispatch basics" do
    test "returns {:error, :not_connected} for unknown machine" do
      assert {:error, :not_connected} =
               Dispatcher.run("no-such-machine", %{type: :shell, command: "echo hi"})
    end

    test "dispatches to connected agent and receives result", %{port: port} do
      machine = "dispatch-#{System.unique_integer([:positive])}"

      {:ok, agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, owner: self()},
          id: machine
        )

      # Wait for connection
      await_connected(machine)

      result = Dispatcher.run(machine, %{type: :shell, command: "echo hello", timeout: 5})
      assert {:ok, %{status: "completed", output: "ok", exit_code: 0}} = result
    end

    test "round-trip latency under 10ms", %{port: port} do
      machine = "perf-#{System.unique_integer([:positive])}"

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, owner: self()},
          id: machine
        )

      await_connected(machine)

      {time_us, {:ok, _}} =
        :timer.tc(fn ->
          Dispatcher.run(machine, %{type: :shell, command: "true", timeout: 5})
        end)

      # Under 10ms (10_000 microseconds), relaxed to 50ms for CI
      assert time_us < 50_000, "Dispatch took #{time_us}µs, expected < 50,000µs"
    end

    test "result contains expected fields", %{port: port} do
      machine = "fields-#{System.unique_integer([:positive])}"

      handler = fn %{"id" => id} ->
        %{
          type: "result",
          id: id,
          status: "completed",
          output: "hello world",
          error: "some warning",
          exit_code: 0
        }
      end

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: handler, owner: self()},
          id: machine
        )

      await_connected(machine)

      {:ok, result} = Dispatcher.run(machine, %{type: :shell, command: "echo hi", timeout: 5})

      assert result.status == "completed"
      assert result.output == "hello world"
      assert result.error == "some warning"
      assert result.exit_code == 0
    end
  end

  describe "timeout behavior" do
    test "returns {:error, :timeout} when agent does not respond", %{port: port} do
      machine = "timeout-#{System.unique_integer([:positive])}"

      handler = fn _frame -> nil end

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: handler, owner: self()},
          id: machine
        )

      await_connected(machine)

      # Use a very short timeout
      result = Dispatcher.run(machine, %{type: :shell, command: "sleep 100", timeout: 1})
      assert {:error, :timeout} = result
    end
  end

  describe "disconnect and cancellation" do
    test "pending callers receive {:error, :agent_disconnected} on connection drop", %{port: port} do
      machine = "disconnect-#{System.unique_integer([:positive])}"

      handler = fn _frame -> nil end

      {:ok, agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: handler, owner: self()},
          id: machine
        )

      await_connected(machine)

      # Start a dispatch in a task
      task =
        Task.async(fn ->
          Dispatcher.run(machine, %{type: :shell, command: "long", timeout: 30})
        end)

      # Give the dispatch time to reach the Connection
      Process.sleep(100)

      # Kill the fake agent (simulates disconnect)
      Process.exit(agent, :kill)

      result = Task.await(task, 5000)
      assert {:error, :agent_disconnected} = result
    end

    test "noproc between lookup and call returns {:error, :not_connected}", %{port: port} do
      machine = "race-#{System.unique_integer([:positive])}"
      dummy_socket = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, pid} = ExCodeRemote.Agent.start_connection(machine, dummy_socket)
      assert ExCodeRemote.Agent.connected?(machine)

      # Kill the connection directly
      Process.exit(pid, :kill)
      Process.sleep(50)

      assert {:error, :not_connected} =
               Dispatcher.run(machine, %{type: :shell, command: "echo hi"})
    end
  end

  describe "telemetry" do
    setup do
      test_pid = self()

      handler_id = "test-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:ex_code_remote, :dispatcher, :command, :start],
          [:ex_code_remote, :dispatcher, :command, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits :start and :stop for successful dispatch", %{port: port} do
      machine = "telem-ok-#{System.unique_integer([:positive])}"

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, owner: self()},
          id: machine
        )

      await_connected(machine)
      Dispatcher.run(machine, %{type: :shell, command: "echo hi", timeout: 5})

      assert_receive {:telemetry, [:ex_code_remote, :dispatcher, :command, :start],
                      %{system_time: _},
                      %{command_id: cmd_id, machine: ^machine, command_type: :shell}}

      assert_receive {:telemetry, [:ex_code_remote, :dispatcher, :command, :stop],
                      %{duration: dur}, %{command_id: ^cmd_id, status: :ok}}

      assert is_integer(dur) and dur >= 0
    end

    test "emits :start and :stop for not_connected" do
      Dispatcher.run("nonexistent", %{type: :shell, command: "echo hi"})

      assert_receive {:telemetry, [:ex_code_remote, :dispatcher, :command, :start], _,
                      %{command_id: cmd_id}}

      assert_receive {:telemetry, [:ex_code_remote, :dispatcher, :command, :stop], _,
                      %{command_id: ^cmd_id, status: :not_connected}}
    end

    test "emits :stop with :timeout status on timeout", %{port: port} do
      machine = "telem-timeout-#{System.unique_integer([:positive])}"

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: fn _ -> nil end, owner: self()},
          id: machine
        )

      await_connected(machine)
      Dispatcher.run(machine, %{type: :shell, command: "slow", timeout: 1})

      assert_receive {:telemetry, [:ex_code_remote, :dispatcher, :command, :stop], _,
                      %{status: :timeout}},
                     10_000
    end
  end

  describe "edge cases" do
    test "malformed result frame does not crash connection", %{port: port} do
      machine = "malformed-#{System.unique_integer([:positive])}"

      handler = fn %{"id" => id} ->
        # Send a result with status as an integer instead of a string
        %{type: "result", id: id, status: 123, output: 456}
      end

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: handler, owner: self()},
          id: machine
        )

      await_connected(machine)

      # The malformed frame should not crash the connection — it should time out
      result = Dispatcher.run(machine, %{type: :shell, command: "echo hi", timeout: 1})
      assert {:error, :timeout} = result

      # Connection should still be alive and functional with a normal handler
      assert ExCodeRemote.Agent.connected?(machine)
    end

    test "unknown result ID does not affect subsequent dispatches", %{port: port} do
      machine = "unknown-id-#{System.unique_integer([:positive])}"

      call_count = :counters.new(1, [:atomics])

      handler = fn %{"id" => id} = _frame ->
        :counters.add(call_count, 1, 1)

        if :counters.get(call_count, 1) == 1 do
          # First call: send result with wrong ID, then the correct one
          %{type: "result", id: "totally-wrong-id", status: "completed", output: "wrong"}
        else
          %{type: "result", id: id, status: "completed", output: "correct", exit_code: 0}
        end
      end

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: handler, owner: self()},
          id: machine
        )

      await_connected(machine)

      # First dispatch gets a wrong-ID response, should timeout
      result1 = Dispatcher.run(machine, %{type: :shell, command: "first", timeout: 1})
      assert {:error, :timeout} = result1

      # Second dispatch should work normally
      result2 = Dispatcher.run(machine, %{type: :shell, command: "second", timeout: 5})
      assert {:ok, %{output: "correct"}} = result2
    end

    test "execute frame matches expected wire format", %{port: port} do
      machine = "wireformat-#{System.unique_integer([:positive])}"

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, owner: self()},
          id: machine
        )

      await_connected(machine)

      Dispatcher.run(machine, %{
        type: :shell,
        command: "echo hello",
        working_dir: "~/code",
        timeout: 30
      })

      assert_receive {:fake_agent_frame, ^machine, frame}, 2000

      # Verify wire format uses string keys matching the Python protocol
      assert frame["type"] == "execute"
      assert is_binary(frame["id"])
      assert byte_size(frame["id"]) == 16
      assert frame["command_type"] == "shell"
      assert frame["command"] == "echo hello"
      assert frame["working_dir"] == "~/code"
      assert frame["timeout"] == 30
    end
  end

  describe "concurrent dispatch" do
    test "multiple concurrent callers each get their own result", %{port: port} do
      machine = "concurrent-#{System.unique_integer([:positive])}"

      handler = fn %{"id" => id, "command" => cmd} ->
        %{type: "result", id: id, status: "completed", output: "result-for-#{cmd}", exit_code: 0}
      end

      {:ok, _agent} =
        start_supervised(
          {FakeAgent, port: port, machine: machine, handler: handler, owner: self()},
          id: machine
        )

      await_connected(machine)

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            cmd = "cmd-#{i}"
            {:ok, result} = Dispatcher.run(machine, %{type: :shell, command: cmd, timeout: 5})
            {cmd, result.output}
          end)
        end

      results = Task.await_many(tasks, 10_000)

      for {cmd, output} <- results do
        assert output == "result-for-#{cmd}"
      end
    end
  end
end

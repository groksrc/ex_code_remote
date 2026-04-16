defmodule ExCodeRemote.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExCodeRemote.Test.FakeAgent
  import ExCodeRemote.Test.Helpers

  setup do
    test_pid = self()
    handler_id = "test-telemetry-#{System.unique_integer([:positive])}"

    all_events = [
      [:ex_code_remote, :dispatcher, :command, :start],
      [:ex_code_remote, :dispatcher, :command, :stop],
      [:ex_code_remote, :agent, :connected],
      [:ex_code_remote, :agent, :disconnected],
      [:ex_code_remote, :agent, :replaced],
      [:ex_code_remote, :http, :request, :stop]
    ]

    :telemetry.attach_many(
      handler_id,
      all_events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    {:ok, handler_id: handler_id}
  end

  defp setup_server(_context) do
    {:ok, server} =
      Bandit.start_link(plug: ExCodeRemote.Router, port: 0, scheme: :http)

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    on_exit(fn -> Process.exit(server, :kill) end)
    {:ok, port: port}
  end

  describe "dispatcher events" do
    setup :setup_server

    test "emits :start and :stop with correct metadata", %{port: port} do
      machine = "telem-dispatch-#{System.unique_integer([:positive])}"

      {:ok, _} =
        start_supervised({FakeAgent, port: port, machine: machine, owner: self()}, id: machine)

      await_connected(machine)

      ExCodeRemote.Commands.Dispatcher.run(machine, %{
        type: :shell,
        command: "echo hi",
        timeout: 5
      })

      assert_receive {:telemetry_event, [:ex_code_remote, :dispatcher, :command, :start],
                      %{system_time: _}, meta}

      assert is_binary(meta.machine)
      assert is_binary(meta.command_id)
      assert meta.command_type == :shell

      assert_receive {:telemetry_event, [:ex_code_remote, :dispatcher, :command, :stop],
                      %{duration: d}, meta}

      assert is_integer(d) and d >= 0
      assert meta.status == :ok
    end
  end

  describe "connection events" do
    setup :setup_server

    test "emits :connected on agent connect", %{port: port} do
      machine = "telem-connect-#{System.unique_integer([:positive])}"

      {:ok, _} =
        start_supervised({FakeAgent, port: port, machine: machine, owner: self()}, id: machine)

      assert_receive {:telemetry_event, [:ex_code_remote, :agent, :connected], %{system_time: _},
                      %{machine: ^machine}},
                     2000
    end

    test "emits :disconnected on agent disconnect with pending_count and reason", %{port: port} do
      machine = "telem-disconnect-#{System.unique_integer([:positive])}"

      {:ok, agent} =
        start_supervised({FakeAgent, port: port, machine: machine, owner: self()}, id: machine)

      await_connected(machine)

      # Drain the :connected event
      assert_receive {:telemetry_event, [:ex_code_remote, :agent, :connected], _, _}, 1000

      Process.exit(agent, :kill)

      assert_receive {:telemetry_event, [:ex_code_remote, :agent, :disconnected], %{duration: d},
                      meta},
                     2000

      assert is_integer(d) and d >= 0
      assert meta.machine == machine
      assert is_atom(meta.reason)
      assert is_integer(meta.pending_count)
    end

    test "emits :replaced on reconnect", %{port: port} do
      machine = "telem-replace-#{System.unique_integer([:positive])}"

      {:ok, _} =
        start_supervised({FakeAgent, port: port, machine: machine, owner: self()},
          id: :"#{machine}-1"
        )

      await_connected(machine)

      # Drain the first :connected
      assert_receive {:telemetry_event, [:ex_code_remote, :agent, :connected], _, _}, 1000

      # Connect again with same machine name
      {:ok, _} =
        start_supervised({FakeAgent, port: port, machine: machine, owner: self()},
          id: :"#{machine}-2"
        )

      await_connected(machine)

      assert_receive {:telemetry_event, [:ex_code_remote, :agent, :replaced], %{system_time: _},
                      %{machine: ^machine, old_pid: old_pid}},
                     2000

      assert is_pid(old_pid)
    end
  end

  describe "HTTP events" do
    setup :setup_server

    test "emits request stop for /health", %{port: port} do
      {:ok, _resp} = :httpc.request(:get, {~c"http://localhost:#{port}/health", []}, [], [])

      assert_receive {:telemetry_event, [:ex_code_remote, :http, :request, :stop], %{duration: d},
                      meta},
                     2000

      assert is_integer(d) and d >= 0
      assert meta.method == "GET"
      assert meta.status == 200
    end

    test "404 has route 'unmatched'", %{port: port} do
      {:ok, _resp} = :httpc.request(:get, {~c"http://localhost:#{port}/nonexistent", []}, [], [])

      assert_receive {:telemetry_event, [:ex_code_remote, :http, :request, :stop], _,
                      %{route: "unmatched", status: 404}},
                     2000
    end
  end

  describe "telemetry handler" do
    test "scrubs sensitive fields from log output" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:ex_code_remote, :dispatcher, :command, :start],
            %{system_time: System.system_time()},
            %{
              machine: "m",
              command_id: "c",
              command_type: :shell,
              content: "secret body",
              auth_token: "secret-token"
            }
          )
        end)

      refute log =~ "secret body"
      refute log =~ "secret-token"
      assert log =~ "machine"
    end

    test "truncates large strings" do
      big_string = String.duplicate("a", 10_000)

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:ex_code_remote, :dispatcher, :command, :start],
            %{system_time: System.system_time()},
            %{machine: "m", command_id: "c", command_type: :shell, big_field: big_string}
          )
        end)

      # Should contain truncated version, not the full 10KB
      refute String.contains?(log, big_string)
      assert log =~ "..."
    end

    test "survives handler error without detachment" do
      # Emit an event with a non-encodable value (a reference)
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:ex_code_remote, :dispatcher, :command, :start],
            %{system_time: System.system_time()},
            %{machine: "m", command_id: "c", command_type: :shell, bad_value: make_ref()}
          )
        end)

      assert log =~ "Telemetry handler failed"

      # Handler should still be attached — emit a normal event
      log2 =
        capture_log(fn ->
          :telemetry.execute(
            [:ex_code_remote, :dispatcher, :command, :start],
            %{system_time: System.system_time()},
            %{machine: "m", command_id: "c2", command_type: :shell}
          )
        end)

      assert log2 =~ "c2"
    end

    test "converts duration to milliseconds in log output" do
      # 1_000_000 native time units
      native_duration = System.convert_time_unit(42, :millisecond, :native)

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:ex_code_remote, :dispatcher, :command, :stop],
            %{duration: native_duration},
            %{machine: "m", command_id: "c", command_type: :shell, status: :ok}
          )
        end)

      assert log =~ "duration_ms"
      refute log =~ "\"duration\""
    end
  end

  describe "metrics module" do
    test "returns a list of metric specs" do
      metrics = ExCodeRemote.Telemetry.Metrics.metrics()
      assert is_list(metrics)
      assert length(metrics) > 0

      for metric <- metrics do
        assert %{__struct__: _} = metric
      end
    end

    test "no metric uses old_pid as a tag" do
      metrics = ExCodeRemote.Telemetry.Metrics.metrics()

      for metric <- metrics do
        tags = Map.get(metric, :tags, [])
        refute :old_pid in tags, "Metric #{inspect(metric.name)} uses old_pid as a tag"
      end
    end

    test "all distribution metrics declare a unit" do
      metrics = ExCodeRemote.Telemetry.Metrics.metrics()

      distributions = Enum.filter(metrics, &match?(%Telemetry.Metrics.Distribution{}, &1))
      assert length(distributions) > 0

      for dist <- distributions do
        assert dist.unit != nil, "Distribution #{inspect(dist.name)} has no unit declared"
      end
    end
  end

  describe "scrub list" do
    test "contains required sensitive fields" do
      scrub_fields = ExCodeRemote.Telemetry.scrub_fields()
      assert :content in scrub_fields
      assert :auth_token in scrub_fields
    end
  end

  describe "log levels" do
    test "dispatcher :stop is logged at info" do
      log =
        capture_log([level: :info], fn ->
          :telemetry.execute(
            [:ex_code_remote, :dispatcher, :command, :stop],
            %{duration: 1000},
            %{machine: "m", command_id: "c", command_type: :shell, status: :ok}
          )
        end)

      assert log =~ "[info]"
    end

    test "agent :disconnected is logged at warning" do
      log =
        capture_log([level: :warning], fn ->
          :telemetry.execute(
            [:ex_code_remote, :agent, :disconnected],
            %{duration: 1000},
            %{machine: "m", reason: :normal, pending_count: 0}
          )
        end)

      assert log =~ "[warning]"
    end
  end
end

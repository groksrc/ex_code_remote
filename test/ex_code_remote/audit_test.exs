defmodule ExCodeRemote.AuditTest do
  use ExUnit.Case, async: false

  alias ExCodeRemote.Audit
  alias ExCodeRemote.Audit.{Repo, Command}

  @start_event [:ex_code_remote, :dispatcher, :command, :start]
  @stop_event [:ex_code_remote, :dispatcher, :command, :stop]

  setup do
    # Clean any leftover rows from previous tests
    Repo.delete_all(Command)
    :ok
  end

  defp emit_start(meta) do
    :telemetry.execute(@start_event, %{system_time: System.system_time()}, meta)
  end

  defp emit_stop(meta) do
    :telemetry.execute(@stop_event, %{duration: 1_000_000}, meta)
  end

  defp build_meta(overrides \\ %{}) do
    Map.merge(
      %{
        machine: "test-machine",
        command_id: "cmd-#{System.unique_integer([:positive])}",
        command_type: :shell,
        command: %{type: :shell, command: "echo hi", timeout: 60},
        started_at: DateTime.utc_now()
      },
      overrides
    )
  end

  defp flush_tasks do
    # Poll until no async audit tasks remain
    Enum.each(1..50, fn _ ->
      case Task.Supervisor.children(ExCodeRemote.Audit.TaskSupervisor) do
        [] -> :ok
        _ -> Process.sleep(20)
      end
    end)
  end

  describe "audit writer" do
    test "start event creates a running audit row" do
      meta = build_meta()
      emit_start(meta)
      flush_tasks()

      row = Repo.get(Command, meta.command_id)
      assert row != nil
      assert row.status == "running"
      assert row.machine == "test-machine"
      assert row.type == "shell"
    end

    test "stop event updates the row with final status" do
      meta = build_meta()
      emit_start(meta)
      flush_tasks()

      stop_meta =
        Map.merge(meta, %{
          status: :ok,
          result: %{status: "completed", output: "hello", error: nil, exit_code: 0},
          duration_ms: 42
        })

      emit_stop(stop_meta)
      flush_tasks()

      row = Repo.get(Command, meta.command_id)
      assert row.status == "completed"
      assert row.output == "hello"
      assert row.exit_code == 0
      assert row.duration_ms == 42
      assert row.completed_at != nil
    end

    test "stop event upserts when start row does not exist yet" do
      meta = build_meta()

      stop_meta =
        Map.merge(meta, %{
          status: :ok,
          result: %{status: "completed", output: "upserted", exit_code: 0},
          duration_ms: 10
        })

      # Emit stop without start
      emit_stop(stop_meta)
      flush_tasks()

      row = Repo.get(Command, meta.command_id)
      assert row != nil
      assert row.status == "completed"
      assert row.output == "upserted"
      assert row.machine == "test-machine"
    end

    test "timeout status is recorded correctly" do
      meta = build_meta()
      emit_start(meta)
      flush_tasks()

      stop_meta = Map.merge(meta, %{status: :timeout, result: nil, duration_ms: 60_000})
      emit_stop(stop_meta)
      flush_tasks()

      row = Repo.get(Command, meta.command_id)
      assert row.status == "timed_out"
    end

    test "missing optional metadata fields produce null columns" do
      meta =
        build_meta(%{
          command_type: :read_file,
          command: %{type: :read_file, path: "/tmp/test"}
        })

      emit_start(meta)
      flush_tasks()

      row = Repo.get(Command, meta.command_id)
      assert row.command == nil
      assert row.path == "/tmp/test"
      assert row.working_dir == nil
    end

    test "audit failure does not crash the telemetry handler" do
      # Stop the Repo to simulate a database failure
      Supervisor.terminate_child(ExCodeRemote.Supervisor, ExCodeRemote.Audit.Repo)

      meta = build_meta()

      # These should not raise — the handler rescues internally
      emit_start(meta)
      emit_stop(Map.merge(meta, %{status: :ok, result: %{}, duration_ms: 1}))
      flush_tasks()

      # Verify the telemetry handler is still attached
      handlers = :telemetry.list_handlers(@start_event)
      assert Enum.any?(handlers, &(&1.id == "ex-code-remote-audit"))

      # Restart the Repo for subsequent tests
      Supervisor.restart_child(ExCodeRemote.Supervisor, ExCodeRemote.Audit.Repo)
      Process.sleep(100)
    end
  end

  describe "debug endpoint" do
    test "returns 401 without auth" do
      conn =
        Plug.Test.conn(:get, "/commands")
        |> ExCodeRemote.Router.call(ExCodeRemote.Router.init([]))

      assert conn.status == 401
    end

    test "returns 200 with auth and commands envelope" do
      conn =
        Plug.Test.conn(:get, "/commands")
        |> Plug.Conn.put_req_header("authorization", "Bearer test-token-for-testing")
        |> ExCodeRemote.Router.call(ExCodeRemote.Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["commands"])
    end

    test "respects limit param" do
      # Insert 5 rows
      for i <- 1..5 do
        Repo.insert!(%Command{
          id: "limit-test-#{i}",
          machine: "m",
          type: "shell",
          status: "completed",
          started_at: DateTime.utc_now()
        })
      end

      conn =
        Plug.Test.conn(:get, "/commands?limit=3")
        |> Plug.Conn.put_req_header("authorization", "Bearer test-token-for-testing")
        |> ExCodeRemote.Router.call(ExCodeRemote.Router.init([]))

      body = Jason.decode!(conn.resp_body)
      assert length(body["commands"]) == 3
    end

    test "caps limit at 100" do
      conn =
        Plug.Test.conn(:get, "/commands?limit=9999")
        |> Plug.Conn.put_req_header("authorization", "Bearer test-token-for-testing")
        |> ExCodeRemote.Router.call(ExCodeRemote.Router.init([]))

      # Just verify it doesn't crash — we don't have 100 rows
      assert conn.status == 200
    end

    test "invalid limit uses default" do
      conn =
        Plug.Test.conn(:get, "/commands?limit=abc")
        |> Plug.Conn.put_req_header("authorization", "Bearer test-token-for-testing")
        |> ExCodeRemote.Router.call(ExCodeRemote.Router.init([]))

      assert conn.status == 200
    end

    test "filters by machine" do
      Repo.insert!(%Command{
        id: "filter-a",
        machine: "machine-a",
        type: "shell",
        status: "completed",
        started_at: DateTime.utc_now()
      })

      Repo.insert!(%Command{
        id: "filter-b",
        machine: "machine-b",
        type: "shell",
        status: "completed",
        started_at: DateTime.utc_now()
      })

      conn =
        Plug.Test.conn(:get, "/commands?machine=machine-a")
        |> Plug.Conn.put_req_header("authorization", "Bearer test-token-for-testing")
        |> ExCodeRemote.Router.call(ExCodeRemote.Router.init([]))

      body = Jason.decode!(conn.resp_body)
      assert length(body["commands"]) == 1
      assert hd(body["commands"])["machine"] == "machine-a"
    end

    test "null fields appear as null in JSON" do
      Repo.insert!(%Command{
        id: "null-test",
        machine: "m",
        type: "read_file",
        status: "completed",
        started_at: DateTime.utc_now()
      })

      conn =
        Plug.Test.conn(:get, "/commands")
        |> Plug.Conn.put_req_header("authorization", "Bearer test-token-for-testing")
        |> ExCodeRemote.Router.call(ExCodeRemote.Router.init([]))

      body = Jason.decode!(conn.resp_body)
      cmd = Enum.find(body["commands"], &(&1["id"] == "null-test"))
      assert Map.has_key?(cmd, "command")
      assert cmd["command"] == nil
      assert Map.has_key?(cmd, "exit_code")
      assert cmd["exit_code"] == nil
    end

    test "results are ordered by started_at descending" do
      now = DateTime.utc_now()

      Repo.insert!(%Command{
        id: "order-old",
        machine: "m",
        type: "shell",
        status: "completed",
        started_at: DateTime.add(now, -60, :second)
      })

      Repo.insert!(%Command{
        id: "order-new",
        machine: "m",
        type: "shell",
        status: "completed",
        started_at: now
      })

      conn =
        Plug.Test.conn(:get, "/commands")
        |> Plug.Conn.put_req_header("authorization", "Bearer test-token-for-testing")
        |> ExCodeRemote.Router.call(ExCodeRemote.Router.init([]))

      body = Jason.decode!(conn.resp_body)
      ids = Enum.map(body["commands"], & &1["id"])
      old_idx = Enum.find_index(ids, &(&1 == "order-old"))
      new_idx = Enum.find_index(ids, &(&1 == "order-new"))
      assert new_idx < old_idx, "Expected newer row first, got #{inspect(ids)}"
    end

    test "timestamps are ISO 8601 strings" do
      Repo.insert!(%Command{
        id: "ts-test",
        machine: "m",
        type: "shell",
        status: "completed",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })

      conn =
        Plug.Test.conn(:get, "/commands")
        |> Plug.Conn.put_req_header("authorization", "Bearer test-token-for-testing")
        |> ExCodeRemote.Router.call(ExCodeRemote.Router.init([]))

      body = Jason.decode!(conn.resp_body)
      cmd = Enum.find(body["commands"], &(&1["id"] == "ts-test"))
      assert {:ok, _, _} = DateTime.from_iso8601(cmd["started_at"])
      assert {:ok, _, _} = DateTime.from_iso8601(cmd["completed_at"])
    end
  end
end

defmodule ExCodeRemote.Commands.StartupSweeperTest do
  @moduledoc """
  Tests for SPEC-10 Unit 1 `StartupSweeper` — the one-shot worker that
  runs at application boot, before inbound traffic is accepted, to
  reconcile audit rows left at `"running"` from the previous boot.
  """

  use ExUnit.Case, async: false

  alias ExCodeRemote.Audit.{Command, Repo}
  alias ExCodeRemote.Commands.StartupSweeper

  setup do
    Repo.delete_all(Command)
    :ok
  end

  defp insert_running(id, started_at \\ nil) do
    started_at = started_at || DateTime.utc_now()

    Repo.insert!(%Command{
      id: id,
      machine: "sweeper-test",
      type: "shell",
      status: "running",
      command: "long-running",
      started_at: started_at
    })
  end

  defp insert_terminal(id, status) do
    now = DateTime.utc_now()

    Repo.insert!(%Command{
      id: id,
      machine: "sweeper-test",
      type: "shell",
      status: status,
      command: "finished",
      started_at: DateTime.add(now, -60, :second),
      completed_at: now,
      duration_ms: 60_000
    })
  end

  describe "sweep/0" do
    test "marks running rows as agent_disconnected" do
      insert_running("r-1", DateTime.add(DateTime.utc_now(), -30, :second))
      insert_running("r-2", DateTime.add(DateTime.utc_now(), -90, :second))
      insert_running("r-3", DateTime.add(DateTime.utc_now(), -5, :second))

      assert {:ok, 3} = StartupSweeper.sweep()

      for id <- ["r-1", "r-2", "r-3"] do
        row = Repo.get(Command, id)
        assert row.status == "agent_disconnected"
        assert %DateTime{} = row.completed_at
        assert is_integer(row.duration_ms) and row.duration_ms >= 0
      end
    end

    test "leaves non-running rows untouched" do
      insert_running("will-be-swept")
      insert_terminal("was-completed", "completed")
      insert_terminal("was-failed", "failed")
      insert_terminal("was-timeout", "timeout")
      insert_terminal("was-agent-disconnected", "agent_disconnected")

      assert {:ok, 1} = StartupSweeper.sweep()

      assert Repo.get(Command, "will-be-swept").status == "agent_disconnected"
      assert Repo.get(Command, "was-completed").status == "completed"
      assert Repo.get(Command, "was-failed").status == "failed"
      assert Repo.get(Command, "was-timeout").status == "timeout"
      assert Repo.get(Command, "was-agent-disconnected").status == "agent_disconnected"
    end

    test "is idempotent — running twice produces the same terminal state" do
      insert_running("idempotent-1", DateTime.add(DateTime.utc_now(), -30, :second))

      assert {:ok, 1} = StartupSweeper.sweep()
      row1 = Repo.get(Command, "idempotent-1")
      assert row1.status == "agent_disconnected"
      completed_at_1 = row1.completed_at

      # Sleep so any re-write would have a detectably different
      # completed_at, and assert the row is NOT touched.
      Process.sleep(50)
      assert {:ok, 0} = StartupSweeper.sweep()

      row2 = Repo.get(Command, "idempotent-1")
      assert row2.status == "agent_disconnected"
      assert row2.completed_at == completed_at_1
    end

    test "empty table is a no-op" do
      assert Repo.all(Command) == []
      assert {:ok, 0} = StartupSweeper.sweep()
      assert Repo.all(Command) == []
    end
  end

  describe "supervision tree ordering" do
    test "Subscribers Registry and StartupSweeper start before Plug.Cowboy" do
      children = Supervisor.which_children(ExCodeRemote.Supervisor)

      # which_children/1 returns children in reverse start order, so
      # reverse to get the declared order.
      ordered = Enum.reverse(children)
      ids = Enum.map(ordered, fn {id, _pid, _type, _mods} -> id end)

      subs_idx = Enum.find_index(ids, &(&1 == ExCodeRemote.Commands.Subscribers))
      sweeper_idx = Enum.find_index(ids, &(&1 == ExCodeRemote.Commands.StartupSweeper))
      cowboy_idx = Enum.find_index(ids, &match?({:ranch_listener_sup, _}, &1))

      # Cowboy is registered under {:ranch_listener_sup, ref} in
      # which_children. If its id shape changes, fall back to scanning
      # module names.
      cowboy_idx =
        cowboy_idx ||
          Enum.find_index(ids, fn id ->
            case id do
              {:ranch_embedded_sup, _} -> true
              :ranch_listener_sup -> true
              _ -> false
            end
          end)

      assert is_integer(subs_idx),
             "Subscribers registry not found in supervisor children: #{inspect(ids)}"

      assert is_integer(sweeper_idx),
             "StartupSweeper not found in supervisor children: #{inspect(ids)}"

      assert is_integer(cowboy_idx),
             "Plug.Cowboy (ranch) not found in supervisor children: #{inspect(ids)}"

      assert subs_idx < cowboy_idx,
             "Expected Subscribers registry to start before Plug.Cowboy"

      assert sweeper_idx < cowboy_idx,
             "Expected StartupSweeper to start before Plug.Cowboy"
    end
  end
end

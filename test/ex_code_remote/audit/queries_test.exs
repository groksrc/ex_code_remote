defmodule ExCodeRemote.Audit.QueriesTest do
  use ExUnit.Case, async: false

  alias ExCodeRemote.Audit.{Command, Queries, Repo}

  setup do
    # Ensure the audit Repo is running. Under normal `mix test`, the
    # application supervisor has already started it; under `mix test
    # --no-start` (or if the application failed to boot for unrelated
    # reasons in a sibling work unit), start it here so this module's
    # tests stay self-contained.
    case Process.whereis(Repo) do
      nil ->
        start_supervised!(Repo)
        # Run migrations so the commands table exists.
        path =
          case :code.priv_dir(:ex_code_remote) do
            {:error, _} -> Path.join([File.cwd!(), "priv", "audit", "migrations"])
            priv_dir -> Path.join([to_string(priv_dir), "audit", "migrations"])
          end

        Ecto.Migrator.run(Repo, path, :up, all: true, log: false)

      _pid ->
        :ok
    end

    # Clean any leftover rows from previous tests so each test starts
    # from a known empty state.
    Repo.delete_all(Command)
    :ok
  end

  defp insert_command(attrs) do
    base = %{
      id: "cmd-#{System.unique_integer([:positive, :monotonic])}",
      machine: "test-machine",
      type: "shell",
      status: "completed",
      command: "echo hi",
      started_at: DateTime.utc_now()
    }

    fields = Map.merge(base, Map.new(attrs))

    Repo.insert!(struct(Command, fields))
  end

  describe "list_commands/1 — ordering" do
    test "returns rows ordered by started_at descending" do
      now = DateTime.utc_now()

      _oldest = insert_command(id: "oldest", started_at: DateTime.add(now, -120, :second))
      _middle = insert_command(id: "middle", started_at: DateTime.add(now, -60, :second))
      _newest = insert_command(id: "newest", started_at: now)

      ids = Queries.list_commands() |> Enum.map(& &1.id)
      assert ids == ["newest", "middle", "oldest"]
    end
  end

  describe "list_commands/1 — limit" do
    test "limit: 5 returns exactly 5 rows when 12 are present" do
      now = DateTime.utc_now()

      for i <- 1..12 do
        insert_command(
          id: "row-#{i}",
          # spread timestamps so ordering is deterministic
          started_at: DateTime.add(now, -i, :second)
        )
      end

      results = Queries.list_commands(limit: 5)
      assert length(results) == 5
    end

    test "limit: 999 is silently capped at 50" do
      now = DateTime.utc_now()

      for i <- 1..60 do
        insert_command(
          id: "cap-#{i}",
          started_at: DateTime.add(now, -i, :second)
        )
      end

      results = Queries.list_commands(limit: 999)
      assert length(results) == 50
    end

    test "default limit is 10 when not provided" do
      now = DateTime.utc_now()

      for i <- 1..15 do
        insert_command(
          id: "default-#{i}",
          started_at: DateTime.add(now, -i, :second)
        )
      end

      results = Queries.list_commands()
      assert length(results) == 10
    end
  end

  describe "list_commands/1 — machine filter" do
    test "machine filter returns only rows for that machine" do
      insert_command(id: "a-1", machine: "machine-a")
      insert_command(id: "a-2", machine: "machine-a")
      insert_command(id: "b-1", machine: "machine-b")

      results = Queries.list_commands(machine: "machine-a")
      ids = Enum.map(results, & &1.id) |> Enum.sort()

      assert ids == ["a-1", "a-2"]
      assert Enum.all?(results, &(&1.machine == "machine-a"))
    end
  end

  describe "list_commands/1 — status filter" do
    test "status filter returns only rows in that status" do
      insert_command(id: "r-1", status: "running")
      insert_command(id: "r-2", status: "running")
      insert_command(id: "c-1", status: "completed")
      insert_command(id: "f-1", status: "failed")

      results = Queries.list_commands(status: "running")
      ids = Enum.map(results, & &1.id) |> Enum.sort()

      assert ids == ["r-1", "r-2"]
      assert Enum.all?(results, &(&1.status == "running"))
    end

    test "status filter for the agent_disconnected literal works" do
      insert_command(id: "ad-1", status: "agent_disconnected")
      insert_command(id: "ad-2", status: "agent_disconnected")
      insert_command(id: "running-1", status: "running")

      results = Queries.list_commands(status: "agent_disconnected")
      ids = Enum.map(results, & &1.id) |> Enum.sort()

      assert ids == ["ad-1", "ad-2"]
    end
  end

  describe "list_commands/1 — since filter" do
    test "since filter returns only rows at or after the cutoff" do
      now = DateTime.utc_now()
      cutoff = DateTime.add(now, -30, :second)

      insert_command(id: "before", started_at: DateTime.add(now, -60, :second))
      insert_command(id: "at-cutoff", started_at: cutoff)
      insert_command(id: "after", started_at: DateTime.add(now, -10, :second))

      results = Queries.list_commands(since: cutoff)
      ids = Enum.map(results, & &1.id) |> Enum.sort()

      assert ids == ["after", "at-cutoff"]
    end
  end

  describe "list_commands/1 — combined filters" do
    test "machine + status are AND'd together" do
      insert_command(id: "a-running", machine: "machine-a", status: "running")
      insert_command(id: "a-completed", machine: "machine-a", status: "completed")
      insert_command(id: "b-running", machine: "machine-b", status: "running")
      insert_command(id: "b-completed", machine: "machine-b", status: "completed")

      results = Queries.list_commands(machine: "machine-a", status: "running")

      assert length(results) == 1
      assert hd(results).id == "a-running"
    end
  end

  describe "list_commands/1 — empty table" do
    test "returns an empty list when no rows exist" do
      assert Queries.list_commands() == []
      assert Queries.list_commands(machine: "anything", status: "running") == []
    end
  end

  describe "get_command_by_id/1" do
    test "happy path: returns the row when it exists" do
      insert_command(id: "lookup-target", machine: "m1", command: "ls -la")

      result = Queries.get_command_by_id("lookup-target")

      assert %Command{id: "lookup-target", machine: "m1", command: "ls -la"} = result
    end

    test "unknown id returns nil and does not raise" do
      assert Queries.get_command_by_id("does-not-exist") == nil
    end

    test "nil id returns nil without raising" do
      assert Queries.get_command_by_id(nil) == nil
    end

    test "empty string id returns nil without raising" do
      assert Queries.get_command_by_id("") == nil
    end
  end
end

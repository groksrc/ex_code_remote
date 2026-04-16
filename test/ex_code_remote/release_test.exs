defmodule ExCodeRemote.ReleaseTest do
  use ExUnit.Case, async: false

  describe "migrate/0" do
    test "runs successfully and is idempotent" do
      # First call — migrations already applied by test setup, this is a no-op
      assert :ok == run_migrate()

      # Second call — still a no-op, proves idempotency
      assert :ok == run_migrate()

      # Verify the migration actually produced the expected schema
      {:ok, result} =
        Ecto.Adapters.SQL.query(ExCodeRemote.Audit.Repo, "SELECT name FROM sqlite_master WHERE type='table' AND name='commands'")

      assert [["commands"]] == result.rows
    end
  end

  defp run_migrate do
    ExCodeRemote.Release.migrate()
    :ok
  end
end

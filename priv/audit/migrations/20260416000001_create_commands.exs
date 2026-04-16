defmodule ExCodeRemote.Audit.Repo.Migrations.CreateCommands do
  use Ecto.Migration

  def change do
    create table(:commands, primary_key: false) do
      add :id, :string, primary_key: true, null: false
      add :machine, :string, null: false
      add :type, :string, null: false
      add :status, :string, null: false
      add :command, :string
      add :path, :string
      add :working_dir, :string
      add :timeout, :integer
      add :output, :text
      add :error, :text
      add :exit_code, :integer
      add :duration_ms, :integer
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
    end

    create index(:commands, [:status])
    create index(:commands, [:machine, :started_at])
    create index(:commands, [:started_at])
  end
end

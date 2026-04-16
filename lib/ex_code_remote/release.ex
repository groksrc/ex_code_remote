defmodule ExCodeRemote.Release do
  @moduledoc """
  Release tasks that run outside the supervision tree.
  Used by the entrypoint script to run migrations before starting the server.
  """

  @app :ex_code_remote

  def migrate do
    load_app()

    for repo <- repos() do
      config = repo.config()
      db_path = Keyword.get(config, :database)

      if db_path do
        parent = Path.dirname(db_path)

        unless File.dir?(parent) do
          raise """
          Database parent directory does not exist: #{parent}
          Create it before running migrations, or ensure the volume is mounted.
          """
        end
      end

      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:logger)
    Application.load(@app)
  end
end

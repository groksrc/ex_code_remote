defmodule ExCodeRemote.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    validate_auth_token!()
    port = Application.get_env(:ex_code_remote, :port, 4000)

    # MCP.Server is supervised per SPEC-5 so it starts on boot. Equally
    # important: ExMCP 0.9.1's MessageProcessor.detect_server_type/1 calls
    # function_exported?/3 without Code.ensure_loaded, so the handler module
    # must already be loaded before the first MCP request arrives. Otherwise
    # detection returns :unknown and falls back to a :direct path that calls
    # get_capabilities/0 (which Handler servers don't implement).
    children = [
      {Registry, keys: :unique, name: ExCodeRemote.AgentRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: ExCodeRemote.AgentSupervisor},
      ExCodeRemote.Audit.Repo,
      {Task.Supervisor, name: ExCodeRemote.Audit.TaskSupervisor, max_children: 100},
      ExCodeRemote.MCP.Server,
      {Plug.Cowboy, plug: ExCodeRemote.Router, scheme: :http, options: [port: port]}
    ]

    opts = [strategy: :one_for_one, name: ExCodeRemote.Supervisor]
    result = Supervisor.start_link(children, opts)

    case result do
      {:ok, _pid} ->
        unless release_mode?(), do: auto_migrate()
        ExCodeRemote.Telemetry.attach()
        ExCodeRemote.Audit.attach()
        Logger.info("ExCodeRemote started on port #{port}")

      _ ->
        :ok
    end

    result
  end

  defp release_mode? do
    System.get_env("RELEASE_NAME") != nil
  end

  defp validate_auth_token! do
    case Application.get_env(:ex_code_remote, :auth_token) do
      nil ->
        raise "AUTH_TOKEN environment variable is required but not set"

      token when is_binary(token) ->
        if String.trim(token) == "" do
          raise "AUTH_TOKEN environment variable is empty or whitespace-only"
        end

        :ok

      _ ->
        raise "AUTH_TOKEN environment variable has an invalid value"
    end
  end

  defp auto_migrate do
    path =
      case :code.priv_dir(:ex_code_remote) do
        {:error, _} -> Path.join([File.cwd!(), "priv", "audit", "migrations"])
        priv_dir -> Path.join([to_string(priv_dir), "audit", "migrations"])
      end

    Ecto.Migrator.run(ExCodeRemote.Audit.Repo, path, :up, all: true, log: false)
  rescue
    e ->
      Logger.error("Auto-migration failed: #{inspect(e)}. Audit system may be unavailable.")
  end
end

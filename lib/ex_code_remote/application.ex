defmodule ExCodeRemote.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:ex_code_remote, :port, 4000)

    children = [
      {Registry, keys: :unique, name: ExCodeRemote.AgentRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: ExCodeRemote.AgentSupervisor},
      {Bandit, plug: ExCodeRemote.Router, port: port, scheme: :http}
    ]

    opts = [strategy: :one_for_one, name: ExCodeRemote.Supervisor]
    result = Supervisor.start_link(children, opts)

    case result do
      {:ok, _pid} ->
        Logger.info("ExCodeRemote started on port #{port}")

      _ ->
        :ok
    end

    result
  end
end

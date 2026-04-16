defmodule ExCodeRemote.Agent do
  @moduledoc "Public facade for agent connection operations."

  require Logger

  @registry ExCodeRemote.AgentRegistry
  @supervisor ExCodeRemote.AgentSupervisor

  @spec connected?(String.t()) :: boolean()
  def connected?(machine) do
    case Registry.lookup(@registry, machine) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  @spec list() :: [String.t()]
  def list do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @spec start_connection(String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def start_connection(machine, socket_pid) do
    # Stop existing connection if one exists (reconnect replacement)
    case Registry.lookup(@registry, machine) do
      [{pid, _}] ->
        Logger.info("Replacing existing connection for machine #{machine}")
        DynamicSupervisor.terminate_child(@supervisor, pid)

      [] ->
        :ok
    end

    case DynamicSupervisor.start_child(
           @supervisor,
           {ExCodeRemote.Agent.Connection, {machine, socket_pid}}
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_registered, _}} ->
        # Race: someone else registered between our stop and start. Retry once.
        Logger.info("Registration conflict for machine #{machine}, retrying")

        case Registry.lookup(@registry, machine) do
          [{pid, _}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
          [] -> :ok
        end

        DynamicSupervisor.start_child(
          @supervisor,
          {ExCodeRemote.Agent.Connection, {machine, socket_pid}}
        )

      error ->
        error
    end
  end

  @spec stop_connection(String.t()) :: {:ok, :stopped} | {:error, :not_connected}
  def stop_connection(machine) do
    case Registry.lookup(@registry, machine) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(@supervisor, pid)
        {:ok, :stopped}

      [] ->
        {:error, :not_connected}
    end
  end

  @spec dispatch(String.t(), map(), pos_integer()) ::
          {:ok, map()} | {:error, :not_connected | :timeout | :agent_disconnected}
  def dispatch(machine, command, timeout_s \\ 60) do
    command = Map.put_new(command, :timeout, timeout_s)
    ExCodeRemote.Commands.Dispatcher.run(machine, command)
  end
end

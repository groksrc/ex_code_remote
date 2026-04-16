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
        :telemetry.execute(
          [:ex_code_remote, :agent, :replaced],
          %{system_time: System.system_time()},
          %{machine: machine, old_pid: pid}
        )

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

  @doc """
  Dispatches a command to the agent without waiting for the reply.
  Returns `{:ok, command_id, started_at}` once the audit row is
  inserted and the execute frame has been queued to the connection
  process. The eventual agent reply is recorded in the audit DB by
  the connection process; subscribers wake up via
  `ExCodeRemote.Commands.Subscribers`.

  Returns `{:error, :not_connected}` if no agent for `machine` is
  registered (no audit row is created — per SPEC-10 Decision 1).
  Returns `{:error, reason}` for other dispatch failures (DB insert
  failure, agent disconnect between lookup and dispatch).
  """
  @spec dispatch_async(String.t(), map()) ::
          {:ok, command_id :: String.t(), started_at :: DateTime.t()}
          | {:error, :not_connected | :agent_disconnected | term()}
  def dispatch_async(machine, command) do
    case Registry.lookup(@registry, machine) do
      [{_pid, _}] ->
        ExCodeRemote.Commands.Dispatcher.run_async(machine, command)

      [] ->
        Logger.info(fn ->
          Jason.encode!(%{
            event: "async_dispatch_rejected",
            reason: "not_connected",
            machine: machine
          })
        end)

        {:error, :not_connected}
    end
  end
end

defmodule ExCodeRemote.Agent.Connection do
  @moduledoc "GenServer managing a single agent's WebSocket connection and in-flight commands."

  use GenServer, restart: :temporary
  require Logger

  alias ExCodeRemote.Commands.Codec

  # Server-side timeout guard adds more slack than the caller's GenServer.call timeout
  # so in normal operation, the caller times out first.
  @server_timeout_slack_ms 10_000

  defstruct [:machine, :socket_pid, :connected_at, :mono_connected_at, pending: %{}]

  def start_link({machine, socket_pid}) do
    GenServer.start_link(__MODULE__, {machine, socket_pid},
      name: {:via, Registry, {ExCodeRemote.AgentRegistry, machine}}
    )
  end

  def child_spec({machine, socket_pid}) do
    %{
      id: {__MODULE__, machine},
      start: {__MODULE__, :start_link, [{machine, socket_pid}]},
      restart: :temporary
    }
  end

  def handle_result(pid, frame) do
    GenServer.cast(pid, {:result, frame})
  end

  # --- Callbacks ---

  @impl true
  def init({machine, socket_pid}) do
    Process.flag(:trap_exit, true)
    Process.monitor(socket_pid)

    :telemetry.execute(
      [:ex_code_remote, :agent, :connected],
      %{system_time: System.system_time()},
      %{machine: machine}
    )

    {:ok,
     %__MODULE__{
       machine: machine,
       socket_pid: socket_pid,
       connected_at: DateTime.utc_now(),
       mono_connected_at: :erlang.monotonic_time()
     }}
  end

  @impl true
  def handle_call({:dispatch, command_id, command}, from, state) do
    if not Process.alive?(state.socket_pid) do
      {:reply, {:error, :not_connected}, state}
    else
      frame = Codec.encode_execute(command_id, command)
      send(state.socket_pid, {:send_frame, frame})

      timeout_ms = command[:timeout] * 1_000 + @server_timeout_slack_ms
      timer_ref = Process.send_after(self(), {:command_timeout, command_id}, timeout_ms)

      new_pending = Map.put(state.pending, command_id, {from, timer_ref})
      {:noreply, %{state | pending: new_pending}}
    end
  end

  @impl true
  def handle_cast({:result, %{"id" => id} = frame}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        Logger.debug("Ignoring result for unknown command ID: #{id}")
        {:noreply, state}

      {{from, timer_ref}, new_pending} ->
        Process.cancel_timer(timer_ref)

        case Codec.decode_result(frame) do
          {:ok, result} ->
            GenServer.reply(from, {:ok, result})
            {:noreply, %{state | pending: new_pending}}

          {:error, :malformed} ->
            Logger.debug("Malformed result frame for command #{id}, discarding")

            new_timer =
              Process.send_after(self(), {:command_timeout, id}, @server_timeout_slack_ms)

            restored = Map.put(new_pending, id, {from, new_timer})
            {:noreply, %{state | pending: restored}}
        end
    end
  end

  @impl true
  def handle_cast({:result, _frame}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:command_timeout, command_id}, state) do
    case Map.pop(state.pending, command_id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, _timer_ref}, new_pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: new_pending}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{socket_pid: pid} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:send_frame, frame}, state) do
    send(state.socket_pid, {:send_frame, frame})
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    # Reply to all pending callers and cancel their timers
    for {_id, {from, timer_ref}} <- state.pending do
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, {:error, :agent_disconnected})
    end

    # Emit disconnected telemetry
    duration =
      if state.mono_connected_at,
        do: :erlang.monotonic_time() - state.mono_connected_at,
        else: 0

    disconnect_reason =
      case reason do
        :normal -> :normal
        :shutdown -> :shutdown
        {:shutdown, _} -> :shutdown
        _ -> :unknown
      end

    :telemetry.execute(
      [:ex_code_remote, :agent, :disconnected],
      %{duration: duration},
      %{
        machine: state.machine,
        reason: disconnect_reason,
        pending_count: map_size(state.pending)
      }
    )

    # Best-effort: instruct socket to close with 1001 (going away)
    send(state.socket_pid, {:close, 1001, "going away"})
    :ok
  end
end

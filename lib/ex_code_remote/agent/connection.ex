defmodule ExCodeRemote.Agent.Connection do
  @moduledoc "GenServer managing a single agent's WebSocket connection and in-flight commands."

  use GenServer, restart: :temporary
  require Logger

  defstruct [:machine, :socket_pid, :connected_at, pending: %{}]

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
    Process.monitor(socket_pid)
    Logger.info("Agent connected: #{machine}")

    {:ok,
     %__MODULE__{
       machine: machine,
       socket_pid: socket_pid,
       connected_at: DateTime.utc_now()
     }}
  end

  @impl true
  def handle_call({:dispatch, _command}, _from, state) do
    {:reply, {:error, :not_implemented}, state}
  end

  @impl true
  def handle_cast({:result, %{"id" => _id} = _frame}, state) do
    # Stub — SPEC-4 will use the pending map to correlate results
    {:noreply, state}
  end

  @impl true
  def handle_cast({:result, _frame}, state) do
    # Result frame missing id — ignore
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{socket_pid: pid} = state) do
    Logger.info("Agent disconnected (socket closed): #{state.machine}")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:send_frame, frame}, state) do
    send(state.socket_pid, {:send_frame, frame})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Best-effort: instruct socket to close with 1001 (going away).
    # send/2 to a dead PID is a silent no-op, so no guard needed.
    send(state.socket_pid, {:close, 1001, "going away"})
    :ok
  end
end

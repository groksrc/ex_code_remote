defmodule ExCodeRemote.Agent.Socket do
  @moduledoc "WebSock handler bridging the raw WebSocket to an Agent.Connection GenServer."

  @behaviour WebSock
  require Logger

  defstruct [:machine, :connection_pid]

  @impl true
  def init(machine) do
    case ExCodeRemote.Agent.start_connection(machine, self()) do
      {:ok, pid} ->
        Process.monitor(pid)
        {:ok, %__MODULE__{machine: machine, connection_pid: pid}}

      {:error, reason} ->
        Logger.error("Failed to start Connection for #{machine}: #{inspect(reason)}")
        # 4-tuple: {stop, reason, close_detail, state} — sends the close frame to the client
        {:stop, :normal, {1011, "internal error"}, %__MODULE__{machine: machine}}
    end
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "result"} = frame} ->
        ExCodeRemote.Agent.Connection.handle_result(state.connection_pid, frame)
        {:ok, state}

      {:ok, %{"type" => "ping"}} ->
        {:push, {:text, Jason.encode!(%{type: "pong"})}, state}

      {:ok, %{"type" => "pong"}} ->
        # Forward to connection for future keepalive use
        {:ok, state}

      {:ok, %{"type" => _unknown}} ->
        # Unknown frame type — silently ignore for forward compatibility
        {:ok, state}

      {:ok, _no_type} ->
        # Frame without type field — ignore
        {:ok, state}

      {:error, _decode_error} ->
        Logger.debug("Malformed JSON frame from #{state.machine}, dropping")
        {:ok, state}
    end
  end

  @impl true
  def handle_in({_data, [opcode: :binary]}, state) do
    # Binary frames are not supported — close with 1003
    {:stop, :normal, {1003, "unsupported data"}, state}
  end

  @impl true
  def handle_info({:send_frame, frame}, state) do
    {:push, {:text, Jason.encode!(frame)}, state}
  end

  @impl true
  def handle_info({:close, code, reason}, state) do
    {:stop, :normal, {code, reason}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{connection_pid: pid} = state) do
    # Connection GenServer died — close the websocket cleanly
    {:stop, :normal, {1011, "internal error"}, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end

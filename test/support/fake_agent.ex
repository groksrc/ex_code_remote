defmodule ExCodeRemote.Test.FakeAgent do
  @moduledoc """
  Test helper that simulates a Python agent. Connects via WebSocket,
  handles incoming execute frames with a configurable response function.
  """

  use GenServer

  alias ExCodeRemote.Test.WSClient

  defstruct [:port, :machine, :ws_state, :handler, :owner]

  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    machine = Keyword.fetch!(opts, :machine)
    handler = Keyword.get(opts, :handler, &default_handler/1)
    owner = Keyword.get(opts, :owner, self())
    token = Keyword.get(opts, :token, "test-token-for-testing")

    GenServer.start_link(__MODULE__, %{
      port: port,
      machine: machine,
      handler: handler,
      owner: owner,
      token: token
    })
  end

  def set_handler(pid, handler) do
    GenServer.call(pid, {:set_handler, handler})
  end

  defp default_handler(%{"id" => id}) do
    %{
      type: "result",
      id: id,
      status: "completed",
      output: "ok",
      error: nil,
      exit_code: 0
    }
  end

  @impl true
  def init(config) do
    case WSClient.connect(config.port,
           token: config.token,
           machine: config.machine
         ) do
      {:ok, ws_state} ->
        {:ok,
         %__MODULE__{
           port: config.port,
           machine: config.machine,
           ws_state: ws_state,
           handler: config.handler,
           owner: config.owner
         }}

      {:error, code, body} ->
        {:stop, {:connection_rejected, code, body}}
    end
  end

  @impl true
  def handle_call({:set_handler, handler}, _from, state) do
    {:reply, :ok, %{state | handler: handler}}
  end

  @impl true
  def handle_info({:delayed_response, response}, state) do
    {:ok, new_ws} = WSClient.send_json(state.ws_state, response)
    {:noreply, %{state | ws_state: new_ws}}
  end

  # Handle raw TCP messages from the Mint connection (active mode)
  @impl true
  def handle_info(message, state) when is_tuple(message) do
    ws = state.ws_state

    case Mint.WebSocket.stream(ws.conn, message) do
      {:ok, conn, responses} ->
        ws = %{ws | conn: conn}

        data =
          Enum.find_value(responses, fn
            {:data, ref, d} when ref == ws.ref -> d
            _ -> nil
          end)

        if data do
          case Mint.WebSocket.decode(ws.websocket, data) do
            {:ok, websocket, frames} ->
              ws = %{ws | websocket: websocket}
              state = %{state | ws_state: ws}
              state = process_frames(frames, state)
              {:noreply, state}

            _ ->
              {:noreply, %{state | ws_state: ws}}
          end
        else
          {:noreply, %{state | ws_state: ws}}
        end

      :unknown ->
        {:noreply, state}

      {:error, _, _reason, _} ->
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp process_frames([], state), do: state

  defp process_frames([{:text, text} | rest], state) do
    case Jason.decode(text) do
      {:ok, frame} ->
        send(state.owner, {:fake_agent_frame, state.machine, frame})

        state =
          if frame["type"] == "execute" do
            handle_execute(frame, state)
          else
            state
          end

        process_frames(rest, state)

      _ ->
        process_frames(rest, state)
    end
  end

  defp process_frames([{:close, _code, _reason} | _rest], state) do
    state
  end

  defp process_frames([_ | rest], state) do
    process_frames(rest, state)
  end

  defp handle_execute(frame, state) do
    case state.handler.(frame) do
      nil ->
        state

      :disconnect ->
        {:ok, new_ws} = WSClient.send_close(state.ws_state)
        %{state | ws_state: new_ws}

      {:delay, ms, response} ->
        Process.send_after(self(), {:delayed_response, response}, ms)
        state

      response when is_map(response) ->
        {:ok, new_ws} = WSClient.send_json(state.ws_state, response)
        %{state | ws_state: new_ws}
    end
  end
end

defmodule ExCodeRemote.Test.WSClient do
  @moduledoc "Minimal WebSocket client for tests using Mint.WebSocket."

  def connect(port, params \\ []) do
    token = Keyword.get(params, :token, "test-token-for-testing")
    machine = Keyword.get(params, :machine, "test-machine")

    query = URI.encode_query(%{token: token, machine: machine})

    {:ok, conn} = Mint.HTTP.connect(:http, "localhost", port)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/ws/agent?#{query}", [])

    receive do
      message ->
        {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)

        {status, headers, rest} = parse_responses(responses, ref)

        case status do
          101 ->
            {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, headers)
            {:ok, %{conn: conn, websocket: websocket, ref: ref}}

          code ->
            body = extract_body(rest, ref)
            {:error, code, body}
        end
    after
      5000 -> {:error, :timeout}
    end
  end

  defp parse_responses(responses, ref) do
    status =
      Enum.find_value(responses, fn
        {:status, ^ref, s} -> s
        _ -> nil
      end)

    headers =
      Enum.find_value(responses, fn
        {:headers, ^ref, h} -> h
        _ -> nil
      end) || []

    rest =
      Enum.reject(responses, fn
        {t, _, _} -> t in [:status, :headers]
        _ -> false
      end)

    {status, headers, rest}
  end

  defp extract_body(rest, ref) do
    Enum.find_value(rest, "", fn
      {:data, ^ref, data} -> data
      _ -> nil
    end)
  end

  def send_text(%{conn: conn, websocket: ws, ref: ref} = state, text) do
    {:ok, ws, data} = Mint.WebSocket.encode(ws, {:text, text})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {:ok, %{state | conn: conn, websocket: ws}}
  end

  def send_json(state, data) do
    send_text(state, Jason.encode!(data))
  end

  def send_binary(%{conn: conn, websocket: ws, ref: ref} = state, binary) do
    {:ok, ws, data} = Mint.WebSocket.encode(ws, {:binary, binary})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {:ok, %{state | conn: conn, websocket: ws}}
  end

  def send_close(%{conn: conn, websocket: ws, ref: ref} = state) do
    {:ok, ws, data} = Mint.WebSocket.encode(ws, :close)
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {:ok, %{state | conn: conn, websocket: ws}}
  end

  def receive_frame(%{conn: conn, websocket: ws, ref: ref} = state, timeout \\ 2000) do
    receive do
      message ->
        {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)

        data =
          Enum.find_value(responses, fn
            {:data, ^ref, d} -> d
            _ -> nil
          end)

        if data do
          {:ok, ws, frames} = Mint.WebSocket.decode(ws, data)
          state = %{state | conn: conn, websocket: ws}

          case frames do
            [{:text, text} | _] -> {:ok, Jason.decode!(text), state}
            [{:close, code, reason} | _] -> {:close, code, reason, state}
            [{:ping, _} | _] -> {:ping, state}
            [{:pong, _} | _] -> {:pong, state}
            [] -> receive_frame(state, timeout)
            other -> {:other, other, state}
          end
        else
          # Non-data response (e.g. stream closed), try again
          state = %{state | conn: conn}
          receive_frame(state, timeout)
        end
    after
      timeout -> {:error, :timeout}
    end
  end
end

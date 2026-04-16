defmodule ExCodeRemote.Plugs.RequestTiming do
  @moduledoc "Plug that emits HTTP request telemetry with duration, method, route, and status."

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    start = :erlang.monotonic_time()

    register_before_send(conn, fn conn ->
      duration = :erlang.monotonic_time() - start

      route =
        case conn.private[:plug_route] do
          {"/*" <> _, _fun} -> "unmatched"
          {route, _fun} -> route
          _ -> "unmatched"
        end

      :telemetry.execute(
        [:ex_code_remote, :http, :request, :stop],
        %{duration: duration},
        %{
          method: conn.method,
          route: route,
          status: conn.status
        }
      )

      conn
    end)
  end
end

defmodule ExCodeRemote.Telemetry do
  @moduledoc "Attaches a telemetry handler that emits structured log lines for all system events."

  require Logger

  @handler_id "ex-code-remote-telemetry-logger"
  @scrub_fields [:content, :auth_token]

  @doc "Returns the list of metadata fields that are scrubbed before logging."
  def scrub_fields, do: @scrub_fields
  @max_string_bytes 200

  @all_events [
    [:ex_code_remote, :dispatcher, :command, :start],
    [:ex_code_remote, :dispatcher, :command, :stop],
    [:ex_code_remote, :dispatcher, :command, :exception],
    [:ex_code_remote, :agent, :connected],
    [:ex_code_remote, :agent, :disconnected],
    [:ex_code_remote, :agent, :replaced],
    [:ex_code_remote, :http, :request, :stop]
  ]

  @event_levels %{
    [:ex_code_remote, :dispatcher, :command, :start] => :info,
    [:ex_code_remote, :dispatcher, :command, :stop] => :info,
    [:ex_code_remote, :dispatcher, :command, :exception] => :error,
    [:ex_code_remote, :agent, :connected] => :info,
    [:ex_code_remote, :agent, :disconnected] => :warning,
    [:ex_code_remote, :agent, :replaced] => :info,
    [:ex_code_remote, :http, :request, :stop] => :info
  }

  def attach do
    :telemetry.attach_many(@handler_id, @all_events, &__MODULE__.handle_event/4, nil)
    Logger.info("Telemetry handler attached, subscribed to #{length(@all_events)} events")
  end

  def handle_event(event, measurements, metadata, _config) do
    level = Map.get(@event_levels, event, :info)

    log_data = %{
      event: Enum.join(event, "."),
      measurements: normalize_measurements(measurements),
      metadata: metadata |> scrub() |> truncate_values()
    }

    Logger.log(level, fn -> Jason.encode!(log_data) end)
  rescue
    e ->
      Logger.error("Telemetry handler failed for #{inspect(event)}: #{Exception.message(e)}")

      :ok
  end

  defp normalize_measurements(%{duration: d} = m) do
    m
    |> Map.put(:duration_ms, System.convert_time_unit(d, :native, :millisecond))
    |> Map.delete(:duration)
  end

  defp normalize_measurements(m), do: m

  defp scrub(metadata) when is_map(metadata) do
    metadata
    |> Map.drop(@scrub_fields)
    |> Map.new(fn
      {:stacktrace, st} when is_list(st) -> {:stacktrace, Exception.format_stacktrace(st)}
      {k, v} -> {k, v}
    end)
  end

  defp truncate_values(metadata) when is_map(metadata) do
    Map.new(metadata, fn {k, v} -> {k, truncate_value(v)} end)
  end

  defp truncate_value(v) when is_binary(v) and byte_size(v) > @max_string_bytes do
    truncate_utf8(v, @max_string_bytes) <> "..."
  end

  defp truncate_value(v), do: v

  defp truncate_utf8(binary, max_bytes) do
    # Truncate at the last complete UTF-8 codepoint at or before max_bytes
    binary
    |> binary_part(0, max_bytes)
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
  end
end

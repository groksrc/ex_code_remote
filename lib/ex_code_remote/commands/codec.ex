defmodule ExCodeRemote.Commands.Codec do
  @moduledoc "Encodes and decodes wire protocol frames between internal maps and JSON-compatible maps."

  @doc "Generates a 16-character URL-safe random command ID."
  def generate_command_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  @doc """
  Builds an execute frame (string-keyed map) from a command map (atom-keyed).
  """
  def encode_execute(command_id, command) do
    %{
      "type" => "execute",
      "id" => command_id,
      "command_type" => command[:type] && to_string(command[:type]),
      "command" => command[:command],
      "path" => command[:path],
      "content" => command[:content],
      "working_dir" => command[:working_dir],
      "timeout" => command[:timeout] || 60
    }
  end

  @doc """
  Parses a result frame (string-keyed map from JSON) into a normalized result map.
  Returns {:ok, result} or {:error, :malformed}.
  """
  def decode_result(%{"id" => id, "status" => status} = frame)
      when is_binary(id) and is_binary(status) do
    {:ok,
     %{
       status: status,
       output: normalize_string(frame["output"]),
       error: normalize_string(frame["error"]),
       exit_code: normalize_exit_code(frame["exit_code"])
     }}
  end

  def decode_result(_frame), do: {:error, :malformed}

  defp normalize_string(val) when is_binary(val), do: val
  defp normalize_string(_), do: nil

  defp normalize_exit_code(val) when is_integer(val), do: val
  defp normalize_exit_code(_), do: nil
end

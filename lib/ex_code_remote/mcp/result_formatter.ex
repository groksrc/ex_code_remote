defmodule ExCodeRemote.MCP.ResultFormatter do
  @moduledoc "Formats dispatch results and errors into text strings matching the Python server's output."

  @spec format({:ok, map()} | {:error, atom()}) :: {:ok, String.t()} | {:error, String.t()}
  def format({:ok, result}) do
    text =
      [
        result[:output],
        result[:error] && result[:error] != "" && "[stderr]: #{result[:error]}",
        result[:exit_code] != nil && "[exit_code: #{result[:exit_code]}]"
      ]
      |> Enum.filter(& &1)
      |> Enum.join("\n")
      |> String.trim()

    {:ok, if(text == "", do: "(no output)", else: text)}
  end

  def format({:error, :not_connected}) do
    {:error, "Error: No agents are connected. Please ensure the agent is running."}
  end

  def format({:error, :agent_disconnected}) do
    {:error, "Error: Agent disconnected before the command completed."}
  end

  def format({:error, :timeout}) do
    {:error, "Error: Command timed out waiting for response."}
  end

  def format({:error, reason}) when is_atom(reason) do
    readable = reason |> Atom.to_string() |> String.replace("_", " ")
    {:error, "Error: Unexpected error: #{readable}"}
  end

  def format({:error, reason}) do
    {:error, "Error: Unexpected error: #{inspect(reason)}"}
  end
end

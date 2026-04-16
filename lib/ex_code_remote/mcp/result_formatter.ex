defmodule ExCodeRemote.MCP.ResultFormatter do
  @moduledoc """
  Formats `Agent.dispatch/3` results into the text strings shipped to MCP
  clients. Successful results follow the Python server's shape; error
  results carry as much detail as we have so the caller can decide what to
  do (retry, raise the timeout, split the work, etc.).
  """

  @type ctx :: %{
          optional(:command) => String.t(),
          optional(:machine) => String.t(),
          optional(:working_dir) => String.t() | nil,
          optional(:timeout) => pos_integer(),
          optional(:path) => String.t()
        }

  @spec format({:ok, map()} | {:error, term()}) ::
          {:ok, String.t()} | {:error, String.t()}
  def format(result), do: format(result, %{})

  @spec format({:ok, map()} | {:error, term()}, ctx()) ::
          {:ok, String.t()} | {:error, String.t()}

  # Agent-reported timeout. The agent killed the process; surface the
  # duration and as much command context as we have.
  def format({:ok, %{status: "timeout"} = result}, ctx) do
    duration = ctx[:timeout] || extract_timeout(result[:error])
    partial = trimmed(result[:output])

    parts = [
      timeout_headline(duration),
      partial && "\nPartial output captured before kill:\n#{partial}",
      partial == nil && "(no output captured before kill)",
      section("Command", ctx[:command]),
      section("Machine", ctx[:machine]),
      section("Working directory", ctx[:working_dir]),
      section("Path", ctx[:path]),
      result[:exit_code] && "[exit_code: #{result[:exit_code]}]"
    ]

    {:error, parts |> Enum.filter(& &1) |> Enum.join("\n")}
  end

  # Normal completed/failed result from the agent.
  def format({:ok, result}, _ctx) do
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

  # Server-side timeout: we never got a reply from the agent within the
  # dispatch budget. Distinct from the agent-reported timeout above —
  # here the command may still be running on the agent.
  def format({:error, :timeout}, ctx) do
    waited =
      case ctx[:timeout] do
        nil -> nil
        # Dispatcher.run adds 5s slack on top of the user-supplied timeout.
        secs -> secs + 5
      end

    headline =
      if waited,
        do:
          "No response from agent after #{waited} seconds. The command may still be running on the agent, or the connection was interrupted.",
        else:
          "No response from agent within the dispatch budget. The command may still be running on the agent."

    parts = [
      headline,
      section("Command", ctx[:command]),
      section("Machine", ctx[:machine]),
      section("Path", ctx[:path])
    ]

    {:error, parts |> Enum.filter(& &1) |> Enum.join("\n")}
  end

  def format({:error, :not_connected}, ctx) do
    machine_clause =
      case ctx[:machine] do
        nil -> ""
        m -> " '#{m}'"
      end

    {:error,
     "No agent#{machine_clause} is connected. Make sure the agent process is running and registered."}
  end

  def format({:error, :agent_disconnected}, ctx) do
    parts = [
      "The agent disconnected before sending a result. Any work already in progress on the agent may have been interrupted.",
      section("Command", ctx[:command]),
      section("Machine", ctx[:machine])
    ]

    {:error, parts |> Enum.filter(& &1) |> Enum.join("\n")}
  end

  def format({:error, reason}, _ctx) when is_atom(reason) do
    readable = reason |> Atom.to_string() |> String.replace("_", " ")
    {:error, "Unexpected error: #{readable}"}
  end

  def format({:error, reason}, _ctx) do
    {:error, "Unexpected error: #{inspect(reason)}"}
  end

  # --- Helpers ---

  defp timeout_headline(nil),
    do: "Command timed out and the agent killed the process."

  defp timeout_headline(secs),
    do: "Command timed out after #{secs} seconds. The agent killed the process."

  defp extract_timeout(nil), do: nil

  defp extract_timeout(msg) when is_binary(msg) do
    case Regex.run(~r/after (\d+) seconds?/, msg) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp extract_timeout(_), do: nil

  defp trimmed(nil), do: nil
  defp trimmed(""), do: nil

  defp trimmed(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  defp trimmed(_), do: nil

  defp section(_label, nil), do: nil
  defp section(_label, ""), do: nil
  defp section(label, value), do: "#{label}: #{value}"
end

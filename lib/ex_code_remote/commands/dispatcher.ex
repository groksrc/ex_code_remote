defmodule ExCodeRemote.Commands.Dispatcher do
  @moduledoc "Routes MCP tool calls to the correct agent connection and awaits the reply."

  alias ExCodeRemote.Commands.Codec

  @default_timeout 60
  @timeout_slack_ms 5_000
  @registry ExCodeRemote.AgentRegistry

  @telemetry_start [:ex_code_remote, :dispatcher, :command, :start]
  @telemetry_stop [:ex_code_remote, :dispatcher, :command, :stop]

  @spec run(String.t(), map()) ::
          {:ok, map()} | {:error, :not_connected | :timeout | :agent_disconnected}
  def run(machine, command) do
    command_id = Codec.generate_command_id()
    command_type = command[:type]
    resolved_timeout = command[:timeout] || @default_timeout

    mono_start = System.monotonic_time()

    :telemetry.execute(@telemetry_start, %{system_time: System.system_time()}, %{
      machine: machine,
      command_id: command_id,
      command_type: command_type
    })

    result =
      case Registry.lookup(@registry, machine) do
        [{pid, _}] ->
          call_timeout = resolved_timeout * 1_000 + @timeout_slack_ms
          command_with_timeout = Map.put_new(command, :timeout, resolved_timeout)

          try do
            GenServer.call(pid, {:dispatch, command_id, command_with_timeout}, call_timeout)
          catch
            :exit, {:timeout, _} -> {:error, :timeout}
            :exit, {:noproc, _} -> {:error, :not_connected}
            :exit, {:normal, _} -> {:error, :not_connected}
            :exit, {:shutdown, _} -> {:error, :not_connected}
            :exit, {_, _} -> {:error, :not_connected}
          end

        [] ->
          {:error, :not_connected}
      end

    duration = System.monotonic_time() - mono_start

    status =
      case result do
        {:ok, _} -> :ok
        {:error, reason} -> reason
      end

    :telemetry.execute(@telemetry_stop, %{duration: duration}, %{
      machine: machine,
      command_id: command_id,
      command_type: command_type,
      status: status
    })

    result
  end
end

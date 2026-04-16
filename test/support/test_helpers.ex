defmodule ExCodeRemote.Test.Helpers do
  @moduledoc "Shared test helpers."

  @doc """
  Waits until the given machine is registered in the Agent Registry.
  Polls every 10ms, times out after the given duration (default 2000ms).
  Raises on timeout.
  """
  def await_connected(machine, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll = fn poll ->
      if ExCodeRemote.Agent.connected?(machine) do
        :ok
      else
        if System.monotonic_time(:millisecond) > deadline do
          raise "Timed out waiting for #{machine} to connect (#{timeout_ms}ms)"
        end

        Process.sleep(10)
        poll.(poll)
      end
    end

    poll.(poll)
  end

  @doc """
  Waits until the given machine is no longer registered.
  """
  def await_disconnected(machine, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll = fn poll ->
      if not ExCodeRemote.Agent.connected?(machine) do
        :ok
      else
        if System.monotonic_time(:millisecond) > deadline do
          raise "Timed out waiting for #{machine} to disconnect (#{timeout_ms}ms)"
        end

        Process.sleep(10)
        poll.(poll)
      end
    end

    poll.(poll)
  end
end

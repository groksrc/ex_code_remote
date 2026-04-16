defmodule ExCodeRemote.Commands.Subscribers do
  @moduledoc """
  In-process pubsub for async command lifecycle notifications.

  Backed by a duplicate-key `Registry` (registered under the same atom
  as this module). Callers subscribe by `command_id` and receive a
  `{:command_done, command_id}` message when the agent connection
  process broadcasts after writing the terminal audit row.

  The broadcast payload carries only the command id; subscribers must
  re-read the audit row to learn the terminal status. This keeps the
  audit DB as the single source of truth even if a future change adds
  new terminal states. See `SPEC-10` §Pubsub for `wait_seconds`.

  Subscribers are auto-cleaned by `Registry` when the subscriber
  process exits, so abandoned waiters do not leak entries.
  """

  @registry __MODULE__

  @doc """
  Registers the calling process to receive `{:command_done, command_id}`
  when `broadcast/1` is called for the same `command_id`.

  Multiple processes may subscribe to the same `command_id`; each will
  receive its own message on broadcast.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(command_id) when is_binary(command_id) do
    {:ok, _pid} = Registry.register(@registry, command_id, nil)
    :ok
  end

  @doc """
  Sends `{:command_done, command_id}` to every process subscribed to
  the given `command_id`. Returns `:ok` even when no subscribers are
  registered (this is the common case for terminal results no one is
  waiting on).
  """
  @spec broadcast(String.t()) :: :ok
  def broadcast(command_id) when is_binary(command_id) do
    Registry.dispatch(@registry, command_id, fn entries ->
      for {pid, _value} <- entries do
        send(pid, {:command_done, command_id})
      end
    end)

    :ok
  end
end

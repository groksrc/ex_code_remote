defmodule ExCodeRemote.Agent.Connection do
  @moduledoc """
  GenServer managing a single agent's WebSocket connection and
  in-flight commands.

  ## In-flight tagging (SPEC-10 contracts §In-flight entry tagging)

  Each in-flight command is keyed by `command_id` in `state.pending`.
  The value is a tagged tuple distinguishing dispatch shape:

      {:sync,  GenServer.from(), command :: map(), timer_ref}
      {:async, command :: map(), started_at :: DateTime.t()}

  The fourth element of the sync variant is the per-command timeout
  timer (existing behavior). The async variant carries the
  `started_at` timestamp the audit row was inserted with so the
  terminate handler can compute `duration_ms` without an extra DB
  read.

  When the agent reply arrives:

  * sync — reply to the original caller (existing behavior).
  * async — UPDATE the existing audit row with the terminal status,
    then `Subscribers.broadcast/1`. Write-then-broadcast ordering is
    required so subscribers re-reading the audit row on wakeup always
    see the final state.
  * unknown id — late reply after `agent_disconnected`. Per
    SPEC-10 §`get_command_result` edge cases, treat this as the
    authoritative terminal state: UPSERT the row, broadcast, and log
    the overwrite.

  ## terminate/2

  For every async entry remaining at termination, mark the audit row
  `agent_disconnected` and broadcast. Sync entries are handled by the
  existing `Dispatcher.run/2` `:noproc`/`:exit` catch and are not
  touched here.

  Brutal kill (`Process.exit(pid, :kill)`) bypasses `terminate/2` by
  design — those rows are reconciled at the next boot by
  `ExCodeRemote.Commands.StartupSweeper`.
  """

  use GenServer, restart: :temporary
  require Logger

  alias ExCodeRemote.Audit.{Command, Repo}
  alias ExCodeRemote.Commands.{Codec, Subscribers}

  # Server-side timeout guard adds more slack than the caller's GenServer.call timeout
  # so in normal operation, the caller times out first.
  @server_timeout_slack_ms 10_000

  defstruct [:machine, :socket_pid, :connected_at, :mono_connected_at, pending: %{}]

  def start_link({machine, socket_pid}) do
    GenServer.start_link(__MODULE__, {machine, socket_pid},
      name: {:via, Registry, {ExCodeRemote.AgentRegistry, machine}}
    )
  end

  def child_spec({machine, socket_pid}) do
    %{
      id: {__MODULE__, machine},
      start: {__MODULE__, :start_link, [{machine, socket_pid}]},
      restart: :temporary
    }
  end

  def handle_result(pid, frame) do
    GenServer.cast(pid, {:result, frame})
  end

  # --- Callbacks ---

  @impl true
  def init({machine, socket_pid}) do
    Process.flag(:trap_exit, true)
    Process.monitor(socket_pid)

    :telemetry.execute(
      [:ex_code_remote, :agent, :connected],
      %{system_time: System.system_time()},
      %{machine: machine}
    )

    {:ok,
     %__MODULE__{
       machine: machine,
       socket_pid: socket_pid,
       connected_at: DateTime.utc_now(),
       mono_connected_at: :erlang.monotonic_time()
     }}
  end

  @impl true
  def handle_call({:dispatch, command_id, command}, from, state) do
    if not Process.alive?(state.socket_pid) do
      {:reply, {:error, :not_connected}, state}
    else
      frame = Codec.encode_execute(command_id, command)
      send(state.socket_pid, {:send_frame, frame})

      timeout_ms = command[:timeout] * 1_000 + @server_timeout_slack_ms
      timer_ref = Process.send_after(self(), {:command_timeout, command_id}, timeout_ms)

      new_pending = Map.put(state.pending, command_id, {:sync, from, command, timer_ref})
      {:noreply, %{state | pending: new_pending}}
    end
  end

  # Async dispatch: enqueue the frame, store an in-flight entry, reply :ok
  # immediately. We do NOT wait for the agent reply; the result is written
  # to the audit DB in handle_cast({:result, ...}) below.
  @impl true
  def handle_call({:dispatch_async, command_id, command, started_at}, _from, state) do
    if not Process.alive?(state.socket_pid) do
      {:reply, {:error, :not_connected}, state}
    else
      frame = Codec.encode_execute(command_id, command)
      send(state.socket_pid, {:send_frame, frame})

      new_pending =
        Map.put(state.pending, command_id, {:async, command, started_at})

      {:reply, :ok, %{state | pending: new_pending}}
    end
  end

  @impl true
  def handle_cast({:result, %{"id" => id} = frame}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        # Late reply for a command we no longer track. Per SPEC-10 this
        # may be a late reply to a row already swept to
        # `agent_disconnected` (either by the connection terminate
        # handler in another connection or by the StartupSweeper). The
        # authoritative answer is what the agent says, so upsert and
        # broadcast.
        case Codec.decode_result(frame) do
          {:ok, result} -> handle_late_async_reply(id, result, state)
          {:error, :malformed} -> Logger.debug("Malformed late result frame for #{id}")
        end

        {:noreply, state}

      {{:sync, from, command, timer_ref}, new_pending} ->
        Process.cancel_timer(timer_ref)

        case Codec.decode_result(frame) do
          {:ok, result} ->
            GenServer.reply(from, {:ok, result})
            {:noreply, %{state | pending: new_pending}}

          {:error, :malformed} ->
            Logger.debug("Malformed result frame for command #{id}, discarding")

            new_timer =
              Process.send_after(self(), {:command_timeout, id}, @server_timeout_slack_ms)

            restored = Map.put(new_pending, id, {:sync, from, command, new_timer})
            {:noreply, %{state | pending: restored}}
        end

      {{:async, _command, started_at}, new_pending} ->
        case Codec.decode_result(frame) do
          {:ok, result} ->
            handle_async_reply(id, result, started_at)
            {:noreply, %{state | pending: new_pending}}

          {:error, :malformed} ->
            Logger.debug(
              "Malformed result frame for async command #{id}, discarding (no in-flight retry)"
            )

            # Drop the entry; the in-flight tracker can't help us if the
            # agent sends garbage. The startup sweep / terminate handler
            # will eventually mark it agent_disconnected if no further
            # frame arrives.
            {:noreply, %{state | pending: new_pending}}
        end
    end
  end

  @impl true
  def handle_cast({:result, _frame}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:command_timeout, command_id}, state) do
    case Map.pop(state.pending, command_id) do
      {nil, _pending} ->
        {:noreply, state}

      {{:sync, from, _command, _timer_ref}, new_pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: new_pending}}

      {{:async, _command, _started_at} = entry, _new_pending} ->
        # Async commands don't run command_timeout timers (the agent
        # owns the timeout); if one slipped through, just put it back.
        {:noreply, %{state | pending: Map.put(state.pending, command_id, entry)}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{socket_pid: pid} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:send_frame, frame}, state) do
    send(state.socket_pid, {:send_frame, frame})
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    {sync_entries, async_entries} = split_pending(state.pending)

    # Sync: cancel timers, reply with :agent_disconnected (existing behavior).
    for {_id, {:sync, from, _command, timer_ref}} <- sync_entries do
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, {:error, :agent_disconnected})
    end

    # Async: write terminal rows + broadcast.
    swept_ids = sweep_async_on_terminate(async_entries, state.machine, reason)

    if swept_ids != [] do
      Logger.info(fn ->
        Jason.encode!(%{
          event: "connection_terminate_swept",
          machine: state.machine,
          command_ids: swept_ids,
          reason: inspect(reason)
        })
      end)
    end

    # Emit disconnected telemetry
    duration =
      if state.mono_connected_at,
        do: :erlang.monotonic_time() - state.mono_connected_at,
        else: 0

    disconnect_reason =
      case reason do
        :normal -> :normal
        :shutdown -> :shutdown
        {:shutdown, _} -> :shutdown
        _ -> :unknown
      end

    :telemetry.execute(
      [:ex_code_remote, :agent, :disconnected],
      %{duration: duration},
      %{
        machine: state.machine,
        reason: disconnect_reason,
        pending_count: map_size(state.pending)
      }
    )

    # Best-effort: instruct socket to close with 1001 (going away)
    send(state.socket_pid, {:close, 1001, "going away"})
    :ok
  end

  # --- Internals ---

  defp split_pending(pending) do
    Enum.reduce(pending, {[], []}, fn
      {_id, {:sync, _from, _cmd, _timer}} = entry, {syncs, asyncs} ->
        {[entry | syncs], asyncs}

      {_id, {:async, _cmd, _started_at}} = entry, {syncs, asyncs} ->
        {syncs, [entry | asyncs]}
    end)
  end

  # Best-effort terminal write for an async reply. Failures here must NOT
  # crash the connection (per SPEC-10 §Error isolation): log at error
  # level, drop the in-flight entry (already done by caller), and
  # broadcast anyway so any waiter wakes up and re-reads (it will see
  # the stale `running` row, which is better than waiting forever).
  defp handle_async_reply(command_id, result, started_at) do
    now = DateTime.utc_now()
    duration_ms = DateTime.diff(now, started_at, :millisecond)

    fields = %{
      status: result[:status] || "completed",
      output: result[:output],
      error: result[:error],
      exit_code: result[:exit_code],
      completed_at: now,
      duration_ms: duration_ms
    }

    case write_terminal_row(command_id, fields) do
      :ok ->
        Logger.info(fn ->
          Jason.encode!(%{
            event: "async_reply_received",
            command_id: command_id,
            status: fields.status
          })
        end)

      {:error, reason} ->
        Logger.error(fn ->
          Jason.encode!(%{
            event: "async_audit_write_failed",
            command_id: command_id,
            error: inspect(reason)
          })
        end)
    end

    Subscribers.broadcast(command_id)
    :ok
  end

  # Late reply: the in-flight entry is gone (terminate handler marked it
  # agent_disconnected, or the StartupSweeper did). Per SPEC-10, the
  # actual reply is authoritative — overwrite. Compute duration_ms from
  # the row's started_at if present so the value is meaningful.
  defp handle_late_async_reply(command_id, result, _state) do
    existing =
      case Process.whereis(Repo) do
        nil -> nil
        _ -> safe_get(command_id)
      end

    previous_status = existing && existing.status

    started_at =
      case existing do
        %Command{started_at: %DateTime{} = s} -> s
        _ -> nil
      end

    now = DateTime.utc_now()

    duration_ms =
      case started_at do
        %DateTime{} = s -> DateTime.diff(now, s, :millisecond)
        _ -> nil
      end

    fields = %{
      status: result[:status] || "completed",
      output: result[:output],
      error: result[:error],
      exit_code: result[:exit_code],
      completed_at: now,
      duration_ms: duration_ms
    }

    case write_terminal_row(command_id, fields) do
      :ok ->
        Logger.info(fn ->
          Jason.encode!(%{
            event: "async_reply_overwrite",
            command_id: command_id,
            previous_status: previous_status,
            new_status: fields.status
          })
        end)

      {:error, reason} ->
        Logger.error(fn ->
          Jason.encode!(%{
            event: "async_audit_write_failed",
            command_id: command_id,
            error: inspect(reason)
          })
        end)
    end

    Subscribers.broadcast(command_id)
    :ok
  end

  defp safe_get(id) do
    Repo.get(Command, id)
  rescue
    _ -> nil
  end

  defp sweep_async_on_terminate(async_entries, _machine, _reason) do
    if async_entries == [] do
      []
    else
      now = DateTime.utc_now()

      for {command_id, {:async, _command, started_at}} <- async_entries do
        duration_ms = DateTime.diff(now, started_at, :millisecond)

        fields = %{
          status: "agent_disconnected",
          completed_at: now,
          duration_ms: duration_ms
        }

        _ = write_terminal_row(command_id, fields)
        Subscribers.broadcast(command_id)
        command_id
      end
    end
  end

  # UPDATE the existing audit row by primary key. The row is inserted
  # (status "running") by Dispatcher.run_async/2 before the frame is
  # sent to the agent, so under normal operation there's always a row
  # to update. If the row is missing (the original insert failed
  # silently, or a late reply raced the delete), fall back to an
  # explicit insert so the broadcast subscribers find a terminal row.
  #
  # Returns :ok or {:error, reason}; never raises.
  defp write_terminal_row(command_id, fields) do
    case Process.whereis(Repo) do
      nil ->
        {:error, :no_repo}

      _ ->
        do_write_terminal_row(command_id, fields)
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp do_write_terminal_row(command_id, fields) do
    case Repo.get(Command, command_id) do
      %Command{} = existing ->
        existing
        |> Ecto.Changeset.change(fields)
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, cs} -> {:error, cs.errors}
        end

      nil ->
        # No existing row — late reply after startup sweep wiped it, or
        # original insert never happened. Insert a minimal row; we don't
        # have machine/command here, so use placeholders rather than
        # silently lose the reply.
        do_upsert_fallback(command_id, fields)
    end
  end

  defp do_upsert_fallback(command_id, fields) do
    # The schema requires non-null `machine`, `type`, `status`,
    # `started_at`. Late replies without these are rare; use "unknown"
    # placeholders rather than drop the result. The StartupSweeper or
    # operator can resolve the mystery row later.
    now = DateTime.utc_now()

    base = %{
      machine: "unknown",
      type: "shell",
      status: fields.status,
      started_at: now
    }

    all_fields = Map.merge(base, fields)

    %Command{id: command_id}
    |> Ecto.Changeset.cast(all_fields, Map.keys(all_fields))
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, cs.errors}
    end
  end
end

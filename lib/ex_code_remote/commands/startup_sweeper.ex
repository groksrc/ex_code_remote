defmodule ExCodeRemote.Commands.StartupSweeper do
  @moduledoc """
  One-shot worker that runs once during application startup to reconcile
  audit rows left in `"running"` status from a previous boot.

  In-flight tracking for both sync and async dispatch lives in the agent
  connection process's in-memory state. When the server restarts (deploy,
  crash, OOM kill) every connection process dies and that state is lost.
  Without this sweep, audit rows that were `"running"` at restart would
  sit at `"running"` indefinitely.

  The sweep marks every such row as `"agent_disconnected"` with a
  `completed_at` of the sweep time and a recomputed `duration_ms`. It
  applies uniformly to rows from both sync and async dispatch since the
  audit schema does not tag them differently.

  ## Ordering

  This module is registered in the supervision tree (`Application.start/2`)
  immediately before `Plug.Cowboy`, so the sweep completes before the HTTP
  listener accepts any inbound traffic. `start_link/1` is synchronous (the
  sweep runs inside `init/1`), so the supervisor only proceeds to start
  `Plug.Cowboy` after the audit DB has been reconciled.

  After the sweep, the GenServer stays alive idle. It accepts no calls or
  casts; this is simpler than coordinating a `:transient` worker exit and
  the memory cost is negligible.

  ## Idempotence

  The sweep query selects only rows with `status = "running"`. After it
  runs, those rows are `"agent_disconnected"`, so a second invocation
  finds zero rows and does nothing. Tests cover this.

  ## Late agent reply

  The agent may in fact still be executing a command that we just marked
  `"agent_disconnected"`. If it later reconnects and sends a `result`
  frame, the late-reply overwrite path in `ExCodeRemote.Agent.Connection`
  upserts the audit row to the actual reply status. See
  `SPEC-10` §`get_command_result` edge cases.
  """

  use GenServer
  require Logger

  alias ExCodeRemote.Audit.{Queries, Repo}

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    sweep()
    {:ok, %{}}
  end

  @doc """
  Performs the sweep. Exposed for testing; the supervisor calls this
  exactly once at boot via `init/1`.
  """
  def sweep do
    case Process.whereis(Repo) do
      nil ->
        Logger.error("startup_sweep_skipped: audit Repo not running")
        :ok

      _pid ->
        do_sweep()
    end
  rescue
    e ->
      Logger.error("startup_sweep_failed: #{Exception.message(e)}")
      :ok
  end

  defp do_sweep do
    rows = Queries.list_running()
    count = length(rows)
    now = DateTime.utc_now()

    Enum.each(rows, fn row ->
      duration_ms =
        case row.started_at do
          %DateTime{} = started_at ->
            DateTime.diff(now, started_at, :millisecond)

          _ ->
            nil
        end

      row
      |> Ecto.Changeset.change(%{
        status: "agent_disconnected",
        completed_at: now,
        duration_ms: duration_ms
      })
      |> Repo.update()
      |> case do
        {:ok, _updated} ->
          :ok

        {:error, changeset} ->
          Logger.error("startup_sweep_reconcile_failed: #{row.id} #{inspect(changeset.errors)}")
      end
    end)

    ids =
      if count <= 20 do
        Enum.map(rows, & &1.id)
      else
        :too_many
      end

    Logger.info(fn ->
      Jason.encode!(%{
        event: "startup_sweep_reconciled",
        count: count,
        command_ids: ids
      })
    end)

    :ok
  end

  # No-op handlers; the GenServer is idle after init/1.
  @impl true
  def handle_call(_msg, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end

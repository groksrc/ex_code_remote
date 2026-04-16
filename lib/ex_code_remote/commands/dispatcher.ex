defmodule ExCodeRemote.Commands.Dispatcher do
  @moduledoc """
  Routes MCP tool calls to the correct agent connection.

  Two entry points:

  * `run/2` — synchronous: dispatch and await the reply (existing
    behavior used by `run_shell_command`, `read_file`, etc.).
  * `run_async/2` — fire-and-don't-wait: insert an audit row in
    `"running"` status, queue the execute frame, and return a
    `command_id` immediately. The eventual reply is recorded by
    `ExCodeRemote.Agent.Connection` directly to the audit DB and
    a `{:command_done, command_id}` broadcast is fired. SPEC-10.
  """

  require Logger

  alias ExCodeRemote.Audit.{Command, Repo}
  alias ExCodeRemote.Commands.Codec

  @default_timeout 60
  @default_async_timeout 600
  @timeout_slack_ms 5_000
  @dispatch_call_timeout_ms 5_000
  @registry ExCodeRemote.AgentRegistry

  @telemetry_start [:ex_code_remote, :dispatcher, :command, :start]
  @telemetry_stop [:ex_code_remote, :dispatcher, :command, :stop]

  @spec run(String.t(), map()) ::
          {:ok, map()} | {:error, :not_connected | :timeout | :agent_disconnected}
  def run(machine, command) do
    command_id = Codec.generate_command_id()
    command_type = command[:type]
    resolved_timeout = command[:timeout] || @default_timeout
    command_with_timeout = Map.put_new(command, :timeout, resolved_timeout)

    mono_start = System.monotonic_time()
    started_at = DateTime.utc_now()

    :telemetry.execute(@telemetry_start, %{system_time: System.system_time()}, %{
      machine: machine,
      command_id: command_id,
      command_type: command_type,
      command: command_with_timeout,
      started_at: started_at
    })

    result =
      case Registry.lookup(@registry, machine) do
        [{pid, _}] ->
          call_timeout = resolved_timeout * 1_000 + @timeout_slack_ms

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

    {status, result_data} =
      case result do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {reason, nil}
      end

    :telemetry.execute(@telemetry_stop, %{duration: duration}, %{
      machine: machine,
      command_id: command_id,
      command_type: command_type,
      command: command_with_timeout,
      started_at: started_at,
      status: status,
      result: result_data,
      duration_ms: System.convert_time_unit(duration, :native, :millisecond)
    })

    result
  end

  @doc """
  Async dispatch path. Returns `{:ok, command_id, started_at}` after
  the audit row is inserted (status `"running"`) and the execute frame
  has been handed to the connection process.

  Per SPEC-10 §`start_command` flow the ordering is:

      registry-lookup -> audit-insert -> dispatch

  Lookup first so a disconnected machine produces no audit row.
  Insert before dispatch so a follow-up `get_command_result` sees the
  row. If dispatch fails (e.g. the connection died between lookup and
  call), update the row to `"agent_disconnected"` and return
  `{:error, :agent_disconnected}` — the audit row is recoverable; a
  silent dispatch with no audit row is not.

  Default timeout is `#{@default_async_timeout}` seconds (per SPEC-10
  §`start_command` arguments). The caller (Unit 3 tool handler)
  clamps to 1..3600.
  """
  @spec run_async(String.t(), map()) ::
          {:ok, command_id :: String.t(), started_at :: DateTime.t()}
          | {:error, :not_connected | :agent_disconnected | term()}
  def run_async(machine, command) do
    command_type = command[:type]
    resolved_timeout = command[:timeout] || @default_async_timeout
    command_with_timeout = Map.put(command, :timeout, resolved_timeout)
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)

    case Registry.lookup(@registry, machine) do
      [] ->
        Logger.info(fn ->
          Jason.encode!(%{
            event: "async_dispatch_rejected",
            reason: "not_connected",
            machine: machine
          })
        end)

        {:error, :not_connected}

      [{pid, _}] ->
        command_id = Codec.generate_command_id()

        case insert_running_row(
               command_id,
               machine,
               command_type,
               command_with_timeout,
               started_at
             ) do
          :ok ->
            do_async_dispatch(
              pid,
              command_id,
              machine,
              command_type,
              command_with_timeout,
              started_at
            )

          {:error, :id_collision} ->
            # Vanishingly unlikely; regenerate once.
            command_id_2 = Codec.generate_command_id()

            case insert_running_row(
                   command_id_2,
                   machine,
                   command_type,
                   command_with_timeout,
                   started_at
                 ) do
              :ok ->
                do_async_dispatch(
                  pid,
                  command_id_2,
                  machine,
                  command_type,
                  command_with_timeout,
                  started_at
                )

              {:error, reason} ->
                Logger.info(fn ->
                  Jason.encode!(%{
                    event: "async_dispatch_rejected",
                    reason: "db_insert_failed",
                    machine: machine,
                    error: inspect(reason)
                  })
                end)

                {:error, reason}
            end

          {:error, reason} ->
            Logger.info(fn ->
              Jason.encode!(%{
                event: "async_dispatch_rejected",
                reason: "db_insert_failed",
                machine: machine,
                error: inspect(reason)
              })
            end)

            {:error, reason}
        end
    end
  end

  defp do_async_dispatch(pid, command_id, machine, command_type, command_with_timeout, started_at) do
    # Emit start telemetry analogous to the sync path so existing
    # observability infrastructure keeps working. The audit terminal
    # write goes directly to the audit DB from the connection
    # process — NOT via telemetry.
    :telemetry.execute(@telemetry_start, %{system_time: System.system_time()}, %{
      machine: machine,
      command_id: command_id,
      command_type: command_type,
      command: command_with_timeout,
      started_at: started_at
    })

    try do
      case GenServer.call(
             pid,
             {:dispatch_async, command_id, command_with_timeout, started_at},
             @dispatch_call_timeout_ms
           ) do
        :ok ->
          Logger.info(fn ->
            Jason.encode!(%{
              event: "async_dispatch_accepted",
              command_id: command_id,
              machine: machine,
              timeout: command_with_timeout[:timeout]
            })
          end)

          {:ok, command_id, started_at}

        {:error, :not_connected} ->
          mark_dispatch_failed(command_id, started_at)

          Logger.info(fn ->
            Jason.encode!(%{
              event: "async_dispatch_rejected",
              reason: "agent_disconnected",
              machine: machine,
              command_id: command_id
            })
          end)

          {:error, :agent_disconnected}
      end
    catch
      :exit, _reason ->
        mark_dispatch_failed(command_id, started_at)

        Logger.info(fn ->
          Jason.encode!(%{
            event: "async_dispatch_rejected",
            reason: "agent_disconnected",
            machine: machine,
            command_id: command_id
          })
        end)

        {:error, :agent_disconnected}
    end
  end

  defp insert_running_row(command_id, machine, command_type, command, started_at) do
    cmd = command || %{}

    fields = %{
      machine: machine,
      type: command_type && to_string(command_type),
      status: "running",
      command: cmd[:command],
      path: cmd[:path],
      working_dir: cmd[:working_dir],
      timeout: cmd[:timeout],
      started_at: started_at
    }

    %Command{id: command_id}
    |> Ecto.Changeset.cast(
      fields,
      [:machine, :type, :status, :command, :path, :working_dir, :timeout, :started_at]
    )
    |> Repo.insert()
    |> case do
      {:ok, _row} ->
        :ok

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if id_unique_violation?(errors) do
          {:error, :id_collision}
        else
          {:error, cs.errors}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp id_unique_violation?(errors) do
    Enum.any?(errors, fn
      {:id, {_msg, opts}} -> Keyword.get(opts, :constraint) in [:unique, "unique"]
      _ -> false
    end)
  end

  defp mark_dispatch_failed(command_id, started_at) do
    now = DateTime.utc_now()
    duration_ms = DateTime.diff(now, started_at, :millisecond)

    case Repo.get(Command, command_id) do
      nil ->
        :ok

      %Command{} = row ->
        row
        |> Ecto.Changeset.change(%{
          status: "agent_disconnected",
          completed_at: now,
          duration_ms: duration_ms
        })
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, _} -> :ok
        end
    end
  rescue
    _ -> :ok
  end
end

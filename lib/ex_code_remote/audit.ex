defmodule ExCodeRemote.Audit do
  @moduledoc "Writes command audit records from dispatcher telemetry events."

  require Logger

  alias ExCodeRemote.Audit.{Repo, Command}

  @task_supervisor ExCodeRemote.Audit.TaskSupervisor

  @start_event [:ex_code_remote, :dispatcher, :command, :start]
  @stop_event [:ex_code_remote, :dispatcher, :command, :stop]

  def attach do
    :telemetry.attach_many(
      "ex-code-remote-audit",
      [@start_event, @stop_event],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(@start_event, _measurements, metadata, _config) do
    async_write(fn -> record_start(metadata) end)
  end

  def handle_event(@stop_event, _measurements, metadata, _config) do
    async_write(fn -> record_stop(metadata) end)
  end

  defp async_write(fun) do
    case Task.Supervisor.start_child(@task_supervisor, fun) do
      {:ok, _pid} ->
        :ok

      {:error, :max_children} ->
        Logger.warning("Audit task supervisor at capacity, dropping write")
        :ok

      {:error, reason} ->
        Logger.error("Failed to spawn audit task: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.error("Audit async_write failed: #{inspect(e)}")
      :ok
  end

  defp record_start(meta) do
    cmd = meta[:command] || %{}

    %Command{id: meta.command_id}
    |> Ecto.Changeset.cast(
      %{
        machine: meta.machine,
        type: meta.command_type && to_string(meta.command_type),
        status: "running",
        command: cmd[:command],
        path: cmd[:path],
        working_dir: cmd[:working_dir],
        timeout: cmd[:timeout],
        started_at: meta[:started_at] || DateTime.utc_now()
      },
      [:machine, :type, :status, :command, :path, :working_dir, :timeout, :started_at]
    )
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.error("Audit start insert failed: #{inspect(changeset.errors)}")
    end
  rescue
    e -> Logger.error("Audit start failed: #{inspect(e)}")
  end

  defp record_stop(meta) do
    cmd = meta[:command] || %{}
    result = meta[:result] || %{}

    status =
      case meta[:status] do
        :ok -> result[:status] || "completed"
        :timeout -> "timed_out"
        :not_connected -> "failed"
        :agent_disconnected -> "failed"
        nil -> "unknown"
        other -> to_string(other)
      end

    fields = %{
      machine: meta[:machine],
      type: meta[:command_type] && to_string(meta[:command_type]),
      status: status,
      command: cmd[:command],
      path: cmd[:path],
      working_dir: cmd[:working_dir],
      timeout: cmd[:timeout],
      output: result[:output],
      error: result[:error],
      exit_code: result[:exit_code],
      duration_ms: meta[:duration_ms],
      started_at: meta[:started_at] || DateTime.utc_now(),
      completed_at: DateTime.utc_now()
    }

    cast_fields = Map.keys(fields)

    # Upsert: if the start row exists, update it. If not (race), insert the full row.
    %Command{id: meta[:command_id]}
    |> Ecto.Changeset.cast(fields, cast_fields)
    |> Repo.insert(
      on_conflict:
        {:replace, [:status, :output, :error, :exit_code, :duration_ms, :completed_at]},
      conflict_target: :id
    )
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.error("Audit stop upsert failed: #{inspect(changeset.errors)}")
    end
  rescue
    e -> Logger.error("Audit stop failed: #{inspect(e)}")
  end
end

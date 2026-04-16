defmodule ExCodeRemote.Audit.Queries do
  @moduledoc """
  Typed query helpers for the audit `commands` table.

  This module is the read layer used by the SPEC-10 async command tools
  (`list_commands`, `get_command_result`). It wraps `ExCodeRemote.Audit.Repo`
  so callers in the tool layer can fetch rows without writing
  `Ecto.Query` or SQL inline.

  All queries are parameterized; no input string is interpolated into
  SQL.

  This module does not validate inputs — input validation (e.g.
  rejecting unknown `status` values) is the caller's responsibility
  (Unit 3, the MCP tool handlers). When given an unknown `status`,
  `list_commands/1` will simply return zero rows. When `get_command_by_id/1`
  is given `nil` or an empty string, it returns `nil` without raising.
  """

  import Ecto.Query, only: [from: 2]

  alias ExCodeRemote.Audit.{Command, Repo}

  @default_limit 10
  @max_limit 50

  @type list_opts :: [
          machine: String.t() | nil,
          status: String.t() | nil,
          limit: pos_integer(),
          since: DateTime.t() | nil
        ]

  @doc """
  Return rows from the `commands` table ordered by `started_at` descending,
  applying any provided filters AND'd together.

  Options:

    * `:machine` — exact-match filter on the `machine` column.
    * `:status`  — exact-match filter on the `status` column. Unknown
      values yield zero rows; the caller is expected to validate.
    * `:limit`   — number of rows to return. Defaults to `#{@default_limit}`.
      Values above `#{@max_limit}` are silently capped at `#{@max_limit}`
      (defensive — the tool layer also clamps).
    * `:since`   — `DateTime`; only rows with `started_at >= since` are
      returned.

  Filters not provided are not applied. Returns an empty list if no rows
  match.
  """
  @spec list_commands(list_opts) :: [Command.t()]
  def list_commands(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> cap_limit()

    base = from(c in Command, order_by: [desc: c.started_at], limit: ^limit)

    base
    |> maybe_filter_machine(Keyword.get(opts, :machine))
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_since(Keyword.get(opts, :since))
    |> Repo.all()
  end

  @doc """
  Look up a single command by its id. Returns the row or `nil` if no row
  exists. Returns `nil` (without raising) when given `nil` or an empty
  string.
  """
  @spec get_command_by_id(String.t() | nil) :: Command.t() | nil
  def get_command_by_id(nil), do: nil
  def get_command_by_id(""), do: nil

  def get_command_by_id(id) when is_binary(id) do
    Repo.get(Command, id)
  end

  @doc """
  Return *every* row in `"running"` status, ordered by `started_at`
  ascending. Unlike `list_commands/1`, this query is uncapped: it is
  intended for `ExCodeRemote.Commands.StartupSweeper`, which needs to
  reconcile every stale row in a single pass at boot. Tool handlers
  (`list_commands`, `get_command_result`) must continue to use
  `list_commands/1` and `get_command_by_id/1`; this helper lives here
  rather than in the sweeper to keep all Ecto query construction in
  one module (per SPEC-10 contracts §Don't-touch list).
  """
  @spec list_running() :: [Command.t()]
  def list_running do
    from(c in Command, where: c.status == "running", order_by: [asc: c.started_at])
    |> Repo.all()
  end

  defp cap_limit(limit) when is_integer(limit) and limit > @max_limit, do: @max_limit
  defp cap_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp cap_limit(_), do: @default_limit

  defp maybe_filter_machine(query, nil), do: query

  defp maybe_filter_machine(query, machine) when is_binary(machine) do
    from(c in query, where: c.machine == ^machine)
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) when is_binary(status) do
    from(c in query, where: c.status == ^status)
  end

  defp maybe_filter_since(query, nil), do: query

  defp maybe_filter_since(query, %DateTime{} = since) do
    from(c in query, where: c.started_at >= ^since)
  end
end

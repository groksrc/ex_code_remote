# SPEC-10 Shared Contracts (Unit 0)

This is the design note pinning down values shared across Units 1–4 so
they can be implemented in parallel without integration-time drift. Each
agreement here is a contract; changes here require updating all
downstream code in the same PR.

## Status literal

The new terminal status added to the `status` column of the existing
`commands` audit table is the string `"agent_disconnected"` (snake
case, no spaces, no hyphens). Used everywhere the status is
serialized: DB rows, JSON-RPC responses, log lines, the
`list_commands` `status` filter enum, the table snapshot test.

The full set of `status` values after this work:

```
running
completed
failed
timeout
agent_disconnected
```

## In-flight entry tagging

The agent connection process maintains an in-flight map keyed by
`command_id`. Each value is a tagged tuple distinguishing dispatch
shape:

```elixir
{:sync, from :: GenServer.from(), command :: map()}
{:async, command :: map(), started_at :: DateTime.t()}
```

The sync variant continues to hold the `GenServer.from()` for
replying to the caller (existing behavior). The async variant carries
the original command map (for potential future use — e.g.,
re-issuing on reconnect; not used in the first cut) and the
`started_at` timestamp the audit row was inserted with (so the
terminate handler can compute `duration_ms` without an extra DB
read).

## Registry

The pubsub registry is named `ExCodeRemote.Commands.Subscribers`.

```elixir
{Registry, keys: :duplicate, name: ExCodeRemote.Commands.Subscribers}
```

Keys are `command_id` strings. Values (the third element of the
registered tuple) are unused; subscribers only care about *that* a
broadcast happened, then re-read the audit row.

Helper module `ExCodeRemote.Commands.Subscribers` (same name as the
registry, fine because the registry is referenced by atom and the
module by alias) wraps the two operations callers need:

```elixir
@spec subscribe(command_id :: String.t()) :: :ok
@spec broadcast(command_id :: String.t()) :: :ok
```

`subscribe/1` calls `Registry.register(@registry, command_id, nil)`.
`broadcast/1` calls `Registry.dispatch/3` and sends `{:command_done,
command_id}` to every registered subscriber pid.

Callers (Units 1, 3) use these helpers, never the registry directly.

## Broadcast message shape

The broadcast payload is the literal tuple:

```elixir
{:command_done, command_id :: String.t()}
```

Carries no status field. Subscribers must re-read the audit row on
receipt. Keeping the payload opaque means the audit DB stays the
single source of truth even if a future change adds new terminal
states.

## Header block key order

Pinned per `SPEC-10` §Tool Surface. Restating here for cross-unit
reference:

`start_command` returns:

```
command_id
status
machine
started_at
command
timeout
```

`get_command_result` running snapshot returns:

```
status
command_id
machine
command
started_at
elapsed
```

`get_command_result` terminal snapshot returns:

```
command_id
status
machine
command
started_at
duration
```

(Followed by a single blank line, then the body produced by
`MCP.ResultFormatter`.)

`list_commands` returns one line per command, fixed-column:

```
<started_at>  <machine>  <status>  <command_id>  <command>
```

Two-space column separators. `status` column padded to 18 chars
(width of `"agent_disconnected"`).

## Timestamps

All output timestamps are UTC ISO-8601 with a trailing `Z`, second
precision. Format string: `DateTime.to_iso8601/1` and trim
sub-seconds via `DateTime.truncate(:second)` before formatting.

Server clock (not agent clock) supplies all timestamps in the audit
row.

## Supervision tree ordering

The `ExCodeRemote.Application.start/2` children list, in order,
becomes:

```
{Registry, keys: :unique, name: ExCodeRemote.AgentRegistry},
{DynamicSupervisor, ..., name: ExCodeRemote.AgentSupervisor},
ExCodeRemote.Audit.Repo,
{Task.Supervisor, name: ExCodeRemote.Audit.TaskSupervisor, ...},
{Registry, keys: :duplicate, name: ExCodeRemote.Commands.Subscribers},  # NEW (Unit 2)
{ExCodeRemote.Commands.StartupSweeper, []},                              # NEW (Unit 1)
{Plug.Cowboy, plug: ExCodeRemote.Router, ...}
```

Both the subscribers Registry and the StartupSweeper must be
registered **before** the agent connection supervisor would be (the
DynamicSupervisor named `AgentSupervisor`). In our current tree the
DynamicSupervisor is already up before incoming WebSockets arrive
(those are handled by the Plug.Cowboy listener at the end), so the
ordering is achieved by ensuring the new entries come before
`Plug.Cowboy` — that's what gates inbound traffic, not the
DynamicSupervisor itself.

`StartupSweeper` is a one-shot worker (Task) that runs the sweep
during startup, then terminates `:normal`. Its job is to reconcile
audit rows in `running` status from the previous boot to
`agent_disconnected`. Synchronous from `start_link/1` — when it
returns, the sweep is done, and the supervisor moves on to start
Plug.Cowboy.

## Module layout

New modules added by Units 1–4:

```
lib/ex_code_remote/commands/subscribers.ex   # Unit 2
lib/ex_code_remote/commands/startup_sweeper.ex   # Unit 1
lib/ex_code_remote/audit/queries.ex          # Unit 4
```

Files modified by Units 1–4:

```
lib/ex_code_remote/agent.ex                  # Unit 1: dispatch_async/2
lib/ex_code_remote/agent/connection.ex       # Unit 1: in-flight async + terminate handler
lib/ex_code_remote/commands/dispatcher.ex    # Unit 1: run_async/2
lib/ex_code_remote/application.ex            # Unit 2: supervision tree edits (and Unit 1 adds StartupSweeper)
lib/ex_code_remote/mcp/tools.ex              # Unit 3: 3 new tool defs + handlers
lib/ex_code_remote/mcp/plug.ex               # No changes anticipated
lib/ex_code_remote/audit/repo.ex             # No changes (Queries module wraps it)
```

## Logging

All async-lifecycle log lines must be greppable by `command_id` and
include enough metadata to trace a single command end-to-end. Match
the existing structured-log style used by sync tools (LoggerJSON
formatter in prod; plain Logger.info in dev/test).

Required fields on each event:

- `event` — short stable name (e.g. `"async_dispatch_accepted"`,
  `"async_reply_received"`, `"startup_sweep_reconciled"`)
- `command_id` — when scoped to a single command
- `machine` — when known
- Additional context per event listed in SPEC-10 §Observability

## Testing harness

Reuse `ExCodeRemote.Test.FakeAgent` and `ExCodeRemote.Test.WSClient`.
Both are unchanged for this work — async dispatch produces identical
WebSocket frames to sync dispatch, and the result frame the fake
agent sends back is decoded identically.

The plug-test harness (`ExCodeRemote.MCP.PlugTest`) gets new
describe blocks for `start_command`, `get_command_result`, and
`list_commands`. The test helper `ExCodeRemote.Test.Helpers` is
unchanged.

## Don't-touch list

To avoid unintended drift in this PR:

- Existing `run_shell_command` behavior (other than its tool
  description text — see SPEC-10 §"Tool selection by the LLM
  caller").
- Any other sync tool (`read_file`, `write_file`, `list_directory`,
  `check_agent_status`).
- The wire protocol with the agent.
- The `Audit.Repo` module's responsibility surface (Queries module
  is layered on top).

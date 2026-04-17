---
title: 'SPEC-10: Async Command Tools'
type: spec
permalink: specs/spec-10-async-command-tools
tags:
- mcp
- tools
- async
- audit
- claude
status: implemented
---

# SPEC-10: Async Command Tools

## Why

Synchronous tool calls hit a hard ceiling at 50 seconds. Fly's HTTP proxy
cuts any single request that hasn't sent a byte in 60 seconds, and that
isn't governed by `http_options.idle_timeout` (verified empirically — see
the comment in `fly.toml`). To keep timeout errors actually reaching the
caller, `MCP.Tools` clamps `run_shell_command` at 50s. That covers most
interactive operations but leaves a real gap for the workloads users
reach for code-remote to handle in the first place: building, running
test suites, long migrations, large file uploads, scraping jobs.

The deeper problem is shape, not duration. Even if Fly let us hold a
connection for an hour, blocking the MCP request the whole time is the
wrong UX. The primary caller is Claude (the LLM client speaking the
Model Context Protocol), used most often from chat on mobile, where
the natural rhythm is "kick it off, the turn ends, check back when it's
interesting again." Holding a turn open for five minutes spins a
loading state, drops on connection blips, wastes context, and
eliminates the possibility of doing anything else in the meantime.

The right answer is async tools: start a command, get back an id,
return the turn, look up the result later (in the same conversation, or
days later) by id or by browsing recent commands.

**Customer impact:** Every workload that currently fails with "timed
out after 50 seconds" becomes possible. The pattern of "do this then
tell me when it's done" — which is how the operator naturally describes
async work in conversation — becomes directly expressible in tool
calls. For long jobs, the operator can disconnect, do something else,
come back later, and ask Claude to check on the result; today that
conversation has no plumbing behind it.

**What changes for the operator:** Today, the operator cannot kick off
a build or a test suite from mobile chat and walk away — the turn will
time out and the result is lost. After this work, the same operator
can dispatch the job, let the conversation go idle, and pick it back
up later with a complete, formatted result. This is the pattern that
moves code-remote from "useful for quick commands" to "useful for the
full range of work an operator actually does from their phone."

**Strategic fit:** This is on the direct path between code-remote's
current capability (reliable sync shell and file tools from SPEC-5)
and the long-term product intent (a persistent, conversational
operations surface that works as naturally from mobile chat as from a
terminal). Async dispatch is the single largest blocker to that path
and unlocks every follow-up workflow that depends on commands taking
longer than a turn.

**Stakeholders:**

- **Primary user (operator):** the human conversing with Claude, who
  dispatches commands against one or more connected agents. Usage is
  predominantly mobile chat.
- **MCP client (Claude):** consumes the tool surface. The text shapes
  defined here are tuned for how an LLM will summarize or quote them
  back to the operator.
- **Connected agents:** existing Python agent processes that already
  speak the wire protocol. They are not being modified by this work
  but their behavior under the new dispatch path must be respected.
- **Operator on call:** anyone reading server logs to debug stuck
  commands or disconnected agents; the observability section is
  written for this audience.

## What

**Dependencies:** SPEC-3 (agent connection), SPEC-4 (command dispatcher),
SPEC-5 (MCP tool surface), SPEC-6 (audit log). No agent-side changes
required — the existing `execute` / `result` wire protocol already
supports this; the change is purely in how the server treats the
correlation between request and reply.

**Downstream dependents:** A future spec may extend this with partial
output streaming (`progress` frames from the agent) and explicit
cancellation; both are deliberately deferred. The tool surface and
audit lifecycle introduced here are the foundation those follow-ups
build on, so the shape chosen here should anticipate — without
implementing — both.

**In scope:**

- Three new MCP tools:
  - `start_command` — dispatch a shell command without blocking; return
    a `command_id` and the initial status.
  - `get_command_result` — look up a command by id; optionally block
    briefly for it to finish.
  - `list_commands` — page through recent commands, optionally filtered
    by machine or status, so callers can find an id they don't
    remember.
- A new dispatch path on the server (an async equivalent to the
  current dispatcher's call path) that sends the command frame to
  the agent but does not wait for the reply. The waiting agent
  connection process is responsible for recording the eventual reply
  to the audit DB.
- Lifecycle tracking using the existing `commands` audit table:
  `running` → (`completed` | `failed` | `timeout` | `agent_disconnected`).
- Result text formatting reuses the existing MCP result formatter so
  async results read identically to sync results when complete.
- An `agent_disconnected` terminal state for async commands whose
  connection died mid-flight, so the audit row doesn't sit at
  `running` forever.
- A startup sweep (see §Server restart) so any audit row left at
  `running` after a server restart is reconciled to a terminal
  state.

**Out of scope (deferred to later specs):**

- Partial output streaming — async commands return no output until
  the agent reports the final result. Useful enough to ship without;
  worth its own spec because it requires agent-side changes (switching
  from buffered process I/O to streamed reads) and a new wire
  frame type.
- Explicit cancellation — `cancel_command` is a natural follow-up but
  also requires a new agent frame and process-group kill semantics.
  Operators can `pkill` via `run_shell_command` in the meantime.
- Notification / push when a command finishes — async always assumes
  pull. The MCP transport is request/response and we have no path to
  the client outside of a tool call.
- Persistence beyond the existing SQLite audit DB.
- Audit retention or pruning policy. The audit table grows
  unboundedly today; async accelerates that growth because it
  unlocks longer workloads and encourages callers to leave rows
  around for later lookup. The operational pressure this creates is
  tracked as a risk here but left to a separate operational spec;
  the trigger for that spec is the first observed degradation in
  `list_commands` read latency or audit DB disk footprint.
- Per-caller / per-session authorization on `command_id`. Any caller
  with access to this MCP server can look up any command in the audit
  DB. That's consistent with how sync tools already expose audit data
  and is out of scope here.
- Redaction of sensitive content in stored output. Command output
  may include secrets (env values echoed by mistake, tokens in
  command-line arguments). The audit DB stores it verbatim, same as
  the sync path. Operators must treat the audit DB as sensitive.

**Boundary with sync tools:** `run_shell_command` stays. It remains the
right tool for any command that is reliably under ~30 seconds and where
the caller will use the result in the very next step. The async tools
are for everything else. The two surfaces will coexist indefinitely;
this spec does not set a deprecation path for sync.

**Tool selection by the LLM caller:** Claude picks tools from their
MCP descriptions. The `start_command` description must explicitly
contrast with `run_shell_command` — something to the effect of "use
this for commands expected to take more than ~30 seconds, or when the
caller wants to end the conversation turn before the result is back."
The `run_shell_command` description should be updated in the same PR to
note that long-running commands should use `start_command` instead.
Without this contrast in the descriptions, Claude defaults to sync for
everything and async never gets used; the exact wording is the
implementer's call but the contrast is not optional.

## Tool Surface

### `start_command`

Arguments:

- `machine` (string, required) — same semantics as `run_shell_command`.
- `command` (string, required).
- `working_dir` (string, optional) — `~` expanded by the agent.
- `timeout` (integer, optional, default 600, max 3600) — command
  timeout in seconds, sent to the agent. The agent kills the process
  group when it fires. The server is not bounded by Fly's 60s here
  because the request returns immediately.

Returns a single text content item (so existing MCP clients render it
without special handling) containing a small structured block with
the command id, status, machine, started-at timestamp, the command
text, and the timeout. The example shape, in the order the server
emits it, is:

```
command_id: <16-char id>
status: running
machine: my-laptop
started_at: 2026-04-16T19:30:00Z
command: echo build; ./run-tests.sh
timeout: 600s
```

Timestamps in all three tools' output are UTC, ISO-8601 with a trailing
`Z`, second precision. The server clock is the source of truth for
`started_at`; the agent reply supplies `completed_at` indirectly via
the server's receipt time, not agent-local clock. This keeps ordering
in `list_commands` monotonic even if the agent's clock drifts.

The header block is a stable, line-oriented key/value format. Keys
are lowercase ASCII, one per line, formatted as `key: value`. The
format is chosen to be greppable in chat, not canonical machine-
readable output. Consumers that want to parse it should split on the
first `: ` per line — that handles colons inside `command` values
without depending on key position.

Key order in the `start_command` header block is fixed:
`command_id`, `status`, `machine`, `started_at`, `command`, `timeout`.
Missing optional fields are omitted rather than rendered as empty
values. A trailing newline is required so `list_commands` and
`get_command_result` output concatenates cleanly in chat clients.

Edge cases:

- Unknown machine — return `isError: true` with the same "No agent
  '<name>' is connected." message the sync tools use. Do not
  allocate a `command_id` and do not insert an audit row for a
  request we never sent (rationale in §Decisions item 1).
- `timeout` ≤ 0 — clamp to 1 (matches sync behavior).
- `timeout` > 3600 — clamp to 3600 with a one-line note appended.
- `timeout` non-integer (floating point, string) — reject with a
  validation `isError: true`; do not silently coerce.
- Missing required arg (`machine` or `command` absent) — reject with
  validation `isError: true` naming the missing field.
- Empty `command` — dispatch it; the agent decides.
- Whitespace-only `command` — dispatch it; the agent decides (same
  policy as sync).
- Multi-line `command` — dispatch unchanged; preserve newlines in the
  audit row. The header block renders the first line followed by
  an ellipsis character for display only.
- `working_dir` that doesn't exist on the agent — dispatch it; the
  agent surfaces the error in the usual terminal result.
- `command_id` collision with an existing audit row — vanishingly
  unlikely given the codec, but if the insert hits a uniqueness
  constraint, regenerate the id and retry once. A second collision
  is treated as a DB error.

### `get_command_result`

Arguments:

- `command_id` (string, required).
- `wait_seconds` (integer, optional, default 0, max 50) — if the
  command is still running, wait up to this many seconds for it to
  finish before responding. Capped at 50 for the same Fly-proxy reason
  the sync tools are. Default 0 means "snapshot whatever is in the
  audit DB right now and return."

Returns one of two text shapes:

- **Still running:** a header block giving status, command id,
  machine, command text, started-at, and elapsed seconds, followed
  by a single line noting that no output has been captured yet
  because partial output streaming is a future enhancement. The
  example shape, in emit order:

  ```
  status: running
  command_id: <id>
  machine: my-laptop
  command: ./run-tests.sh
  started_at: 2026-04-16T19:30:00Z
  elapsed: 47s
  (no output captured yet — partial output streaming is a future
  enhancement)
  ```

- **Terminal** (`completed`, `failed`, `timeout`, `agent_disconnected`):
  a header block giving command id, status, machine, command text,
  started-at, and total duration, followed by a blank line and the
  same body the sync tools produce via the existing result formatter
  (stdout, stderr, exit code, or the context-rich timeout / disconnect
  message). The example shape, in emit order:

  ```
  command_id: <id>
  status: completed
  machine: my-laptop
  command: ./run-tests.sh
  started_at: 2026-04-16T19:30:00Z
  duration: 247s

  <formatted result body>
  ```

Key order in each block is fixed. Running:
`status`, `command_id`, `machine`, `command`, `started_at`, `elapsed`.
Terminal: `command_id`, `status`, `machine`, `command`, `started_at`,
`duration`. (Terminal includes `started_at` so an operator reading
the result later can correlate it with the conversation it came from
without re-querying.) A single blank line separates the header block
from the body; no trailing blank lines.

`elapsed` and `duration` are whole seconds. Compute them by
subtracting the stored UTC timestamps (current time vs. `started_at`
for running rows; `completed_at` vs. `started_at` for terminal
rows). Do not introduce a separate monotonic-time field — the audit
DB carries only wall-clock UTC values, and rounding to whole seconds
makes sub-second skew immaterial.

Edge cases:

- Unknown `command_id` — `isError: true`, message: "No command found
  with id '<id>'. Use list_commands to find recent commands."
- `command_id` that fails format validation (wrong length, illegal
  characters) — `isError: true` with the same "not found" message;
  do not reveal what a valid id looks like beyond the already-public
  codec format.
- `wait_seconds` > 50 — clamp to 50 (silent, matches input-validation
  behavior elsewhere).
- `wait_seconds` < 0 or non-integer — reject with a validation
  `isError: true` rather than clamp; these are caller bugs, not
  ergonomics.
- `wait_seconds` provided for a command that is already terminal —
  return immediately, ignore the wait.
- Concurrent waiters on the same command_id — every waiter must be
  notified when the result arrives. Implementation must not assume a
  single subscriber.
- Late agent reply — a reply frame arrives for a command already
  marked `agent_disconnected` (server thought the connection died,
  the agent thought otherwise, timing beat us). Treat the late reply
  as the authoritative terminal state: overwrite the audit row from
  `agent_disconnected` to the reply's actual status, update
  `completed_at`, broadcast. Log the overwrite for observability.
- Audit DB unavailable — `isError: true` with a clear message;
  `get_command_result` must not crash the tool handler when the DB is
  down during the initial lookup or the post-wait re-read.
- `wait_seconds` deadline hit — return the running snapshot without
  blocking the request handler past the requested deadline (target
  wall-clock overshoot ≤1 second to leave Fly-proxy slack).

### `list_commands`

Arguments:

- `machine` (string, optional) — filter to one machine.
- `status` (string, optional) — one of `running`, `completed`,
  `failed`, `timeout`, `agent_disconnected`. Reject other values with
  a validation error rather than silently returning everything.
- `limit` (integer, optional, default 10, max 50) — number of rows
  returned, ordered by `started_at` descending (most recent first).
- `since` (string, optional) — ISO-8601 timestamp; only return
  commands started at or after this time. Useful for "what have I run
  in the last hour."

`since` accepts any timestamp parseable by the standard ISO-8601
parser (offset required or trailing `Z`). Reject malformed values
with a validation `isError: true` naming the offending argument,
rather than silently treating them as "no filter."

Returns a single text content item with one line per command, in a
fixed-column form chosen so a chat UI renders it readably without
markdown parsing:

```
2026-04-16T19:30:00Z  my-laptop  running    K2uPCVVJYAiW-43Q  ./run-tests.sh
2026-04-16T19:24:11Z  my-laptop  completed  R1MkIlh0xgPAu86z  bundle exec rake db:migrate
2026-04-16T19:22:05Z  my-laptop  failed     53hA9-P8l0ptfwHJ  npm run build
```

Columns are separated by two spaces. The status column is padded to
the width of the longest current status literal (`agent_disconnected`,
18 characters) so columns stay aligned across status values. If a
future spec adds a longer status literal, the padding width must be
updated alongside it; the column-alignment snapshot test will fail
otherwise. Machine and command_id columns are not padded (machine
names vary; command_id is fixed width). Long commands are truncated
to 80 characters with a trailing ellipsis character; multi-line
commands collapse to their first line before truncation. The caller
can `get_command_result` with the id to see the full command.

Line endings are `\n` (not `\r\n`). Empty rows are not emitted. If
the final row in the window is reached before `limit`, do not pad
the output.

Edge cases:

- No matches — return a single text item: `"No commands found."`.
  Don't return an error.
- Unknown `status` value — `isError: true`, list valid values in the
  message.
- Unknown argument keys in the call — reject with a validation
  `isError: true` rather than silently ignore, to surface caller
  typos early.
- Audit DB unavailable — `isError: true` with a clear message; do
  not crash the tool handler.
- `limit` ≤ 0 — clamp to 1.
- `limit` > 50 — clamp to 50 (silent).
- `machine` filter for a machine that has never connected — treat as
  "no matches"; do not error.
- `since` in the future — treat as "no matches"; do not error.
- Combined filters — all provided filters are AND'd; tests cover at
  least one multi-filter case (e.g. `machine` + `status`).

## How (High Level)

### Task Breakdown

Four work units. Unit 0 must be settled before any other unit starts
because it pins down contracts shared across units. Units 1 and 2 are
independent once Unit 0 is agreed. Units 3 and 4 depend on both.

0. **Shared contracts** — before implementation starts, pin down:
   the registry name and broadcast message shape (a tuple carrying
   only the command id) from §Pubsub, the exact `agent_disconnected`
   status literal used in both the schema and formatters, the
   in-flight entry tag values distinguishing sync from async
   dispatch from §Server-side state, and the key order of each
   header block from §Tool Surface. Agreeing these up front lets
   Units 1–4 proceed in parallel without integration-time conflicts.
   Captured in module docs or a short internal design note; no
   separate code artifact required.

1. **Async dispatch path** — extend the agent connection process and
   the commands dispatcher with a "fire and don't wait" path. The
   agent connection process needs to track in-flight async command
   ids and write the result to the audit DB when the agent reply
   arrives, instead of replying to the synchronous caller. No agent
   changes. Exposes an async-dispatch entry point that returns a
   simple ok/error result synchronously once the frame is queued to
   the socket, with the error reason drawn from the same set the
   sync path uses plus a "not connected" reason. Exit criteria: unit
   tests prove that a reply frame received for an async in-flight id
   writes the terminal row without attempting to reply to a
   non-existent caller.

2. **Result subscription / wait_seconds** — a small in-process
   pubsub (a duplicate-key registry) keyed by `command_id` so
   `get_command_result` can block until the agent replies, even
   across processes. Audit-DB row is the source of truth for
   already-terminal commands; pubsub is only needed while
   `running`. Exposes a subscribe helper and a broadcast helper so
   Units 1 and 3 don't reach into the registry directly. Exit
   criteria: unit tests cover subscribe-then-broadcast,
   broadcast-with-no-subscribers (must not error),
   subscriber-exits-before-broadcast (must not leak entries), and
   multiple subscribers on one key.

3. **MCP tool implementations** — `start_command`, `get_command_result`,
   `list_commands` added to the MCP tools module. New tool
   definitions added to the tool list. Use the existing result
   formatter for the result body of `get_command_result`. Depends
   on Units 1, 2, and 4. Exit criteria: the MCP `tools/list` call
   advertises the three tools with the schema constraints documented
   in §Tool Surface; integration tests against the existing fake
   agent harness cover the happy path and each enumerated edge case.

4. **Audit query layer** — a small module on top of the existing
   audit repository for `list_commands` and "get command by id".
   Keep the queries narrow: no joins, single table, ordered/limited
   at the DB level. Exposes typed accessors the tool layer can call
   without writing SQL or query DSL inline. Exit criteria: queries
   are parameterized (no string interpolation), return structs with
   fields named the way the tool handlers expect, and have tests
   exercising each filter independently and combined.

### Wire Protocol (no changes)

The agent sends `result` frames keyed by command id, exactly as today.
The server already correlates by id in the agent connection process.
The only behavioral change is that for async-dispatched commands, the
connection has no synchronous caller to reply to — it instead writes
the result to the audit DB and broadcasts to any waiters.

This is the central reason this spec is small: it's a server-side
behavioral change, not a protocol change. The Python agent ships as-is.

### Server-side state

The agent connection's state already maps `command_id` → caller info
for sync calls. Extend the stored entry with a tag distinguishing
sync (carries a synchronous-caller reference) from async (carries the
original command map needed to populate the audit row on reply).
When the agent reply arrives:

- Look up the in-flight entry by id.
- If tagged as a sync entry, reply to the original caller (existing
  behavior).
- If tagged as an async entry, write the terminal row to the audit
  DB, then broadcast on the registry. Write-then-broadcast ordering
  is required so any subscriber that re-queries on wakeup sees the
  final row.
- Either way, drop the in-flight entry.
- If no entry exists for the id (late reply after
  `agent_disconnected`), follow the overwrite path described in
  `get_command_result` edge cases: upsert the audit row from the
  reply, broadcast on the registry, log the overwrite.

Disconnect handling: when the connection process terminates with
in-flight commands, every async command it owned must be marked
`agent_disconnected` in the audit DB *and* a broadcast sent on the
registry so any active waiters wake. Sync commands are already
handled by the dispatcher's existing missing-process catch. Use a
process-termination callback or a monitoring process that reads the
connection's in-flight map on a `:DOWN` signal; whichever approach
is chosen must survive abnormal exits (brutal kill by supervisor,
raised exceptions), not just clean shutdowns. Tests must exercise
both normal and abnormal exit paths (see §Tests); passing one does
not imply the other.

### Server restart

The in-flight tracking (sync waiters and async owners both) lives in
the agent connection process's in-memory state. When the server
restarts (deploy, crash, OOM kill), every connection process dies
and its in-flight map is lost. Audit rows that were `running` at
restart will sit there indefinitely unless reconciled — this
applies to both sync- and async-dispatched commands, since the audit
schema doesn't tag them differently.

On application start, before any new agent connections are accepted,
sweep the audit table for rows in status `running` (regardless of
which dispatch path created them, since all live in-flight state is
gone after a fresh boot) and mark them `agent_disconnected` with
`completed_at` set to the sweep time. The sweep runs once per boot
and is idempotent. The agent may in fact still be executing the
command after server restart; if it later reconnects and sends a
`result` frame for the now-terminal audit row, the late-reply
overwrite path applies (the actual result replaces the swept-in
`agent_disconnected` state).

### Audit table

The existing schema covers what we need (`id`, `machine`, `type`,
`status`, `command`, `path`, `working_dir`, `timeout`, `output`,
`error`, `exit_code`, `started_at`, `completed_at`, `duration_ms`).
No table-shape migration required. We do introduce one new value for
the `status` column: `agent_disconnected`. Any code that enumerates
valid statuses (validators, type specs, pattern matches, schema
changesets, JSON schema for the `status` filter in `list_commands`)
must be updated to include it — treat this as an audit-wide grep,
not a tool-local change. Exit criterion for this sweep: a grep for
the existing status literals returns zero hits that omit
`agent_disconnected`. Tests should confirm an in-flight async
command whose connection drops ends up with this status and a
`completed_at`, so `list_commands` doesn't show it as
forever-running.

### Pubsub for `wait_seconds`

Use a duplicate-key registry under a stable name (agreed in Unit 0).
Register it in the application supervision tree *before* the agent
connection supervisor so any connection that comes up can publish to
it. Also register the startup-sweep step (see §Server restart)
before the agent connection supervisor accepts traffic.
`get_command_result` with `wait_seconds > 0` follows this ordering:
first look up the command in the audit DB and return if terminal;
otherwise subscribe to the registry under the command id; then
re-check the audit DB to close the race where the result arrives
between the first lookup and the subscribe; then wait for either a
"command done" notification or the deadline; on either path, look up
the audit row and render, returning the running snapshot if the
deadline was hit.

The broadcast payload carries only the command id and no status
field; subscribers must re-read the audit row rather than trust the
payload, so the write-before-broadcast ordering remains the single
source of truth.

This avoids a polling loop, scales to multiple waiters, and stays
contained to a single registry. The agent connection process is the
sole publisher; it broadcasts after the audit-DB write so subscribers
that re-query always see the final row. Registry entries are
automatically cleaned up when the subscriber process exits (standard
registry behavior), so an abandoned waiter doesn't leak.

### `start_command` flow

The tool validates arguments (`machine` and `command` required,
`timeout` clamped to the documented range), looks up the agent in
the registry, generates a `command_id` via the existing codec
helper used by the sync path, inserts an audit row with status
`running` and the command details, sends the `execute` frame to
the connection process via the async-dispatch entry point, and
returns the `command_id` and initial header block.

Lookup ordering matters because the agent-not-connected case must
not leave an audit row behind. Check the agent registry *before*
inserting the audit row: if the machine isn't connected, return
`isError: true` immediately with the same "No agent '<name>' is
connected." message the sync tools use, and do not generate a
`command_id`.

If the agent is connected, insert the audit row synchronously, then
dispatch. The audit-row insert must complete before the tool
returns, so a follow-up `get_command_result` in the next tool call
is guaranteed to see the row. If the dispatch fails (e.g. the agent
disconnects between lookup and send), update the audit row to
`agent_disconnected` and return `isError: true`. If the audit-DB
write itself fails, do not send the frame; return `isError: true`
with the DB error surfaced, so no orphan command exists on the
agent.

Audit-row insert and connection-process dispatch are two separate
side effects that can't be wrapped in a transaction. The ordering
above (insert first, then dispatch) is deliberate: an orphaned
`running` row whose dispatch failed is recoverable (the
connection-terminate handler, the startup sweep, or an operator can
mark it `agent_disconnected`); a lost dispatch with no audit row is
not.

### Concurrency

`start_command` is non-blocking for the caller: it does not wait for
the agent reply. Internally it may use a synchronous handoff to the
connection process, but that handoff must not itself await the agent —
it returns as soon as the frame is queued to the socket.

`get_command_result` blocks the calling request handler for up to
`wait_seconds`, but each request runs in its own process so this
doesn't serialize anything. `list_commands` is a single SQLite read.

There is no shared mutable state added by this spec. Everything is
either in the audit DB (durable) or in the registry (per-key,
garbage-collected when the agent connection terminates or
subscriber exits).

The connection process must accept many in-flight async commands
concurrently without serializing them on each other; the in-flight
map is a per-connection structure, so this is naturally the case,
but the test plan exercises concurrent dispatch to confirm.

### Error isolation

Audit-DB failures must not take down the agent connection. If the
write of a terminal async result fails (disk full, SQLite busy
beyond retries), log at error level, drop the in-flight entry, and
broadcast anyway; a subsequent `get_command_result` will find a
stale `running` row, which is better than a crashed connection that
drops all other in-flight commands.

### Observability

The following events must be logged at `info` or above so operators
can trace async lifecycles without a debugger:

- `start_command` accepted (command_id, machine, timeout).
- `start_command` rejected with reason (unknown machine, DB insert
  failure, dispatch failure).
- Async reply received (command_id, terminal status).
- Async reply overwrite of `agent_disconnected` (command_id, previous
  status, new status).
- Connection-process-terminate sweep marking in-flight async rows
  (connection identifier, command_ids, exit reason).
- Startup sweep reconciling rows left at `running` from the previous
  boot (count, command_ids).
- Audit-DB write failure during async result handling (command_id,
  error).

Log formatting follows whatever convention existing sync tools use;
no new log backend.

## How to Evaluate

### Definition of Done

A user can dispatch a command they expect to take five minutes, end
the conversation turn, return ten minutes later, and either ask Claude
to look up that command by id or by `list_commands`, and get back a
clean result with stdout, stderr, exit code, and duration. The same
user can dispatch a 500ms command via `start_command` plus
`get_command_result` with `wait_seconds=2` and have it feel like a
synchronous call.

The user-experiential bar: the operator does not need to understand
the sync/async split to get the right outcome. Claude picks the right
tool, the operator sees the command land, and when they come back
later the result is there — whether seconds or hours later, whether
the same conversation turn or a fresh one.

### Success Criteria

- [ ] `start_command` returns a valid `command_id` and a `running`
      header block within ≤200ms of the request hitting the server.
- [ ] `start_command` inserts the audit row synchronously before
      returning, verified by an immediate `get_command_result` with
      `wait_seconds=0` finding the row.
- [ ] `start_command` returns `isError: true` without leaving a
      `running` row behind when the audit-DB insert fails or the
      connection-process dispatch fails.
- [ ] `get_command_result` returns the running snapshot for an
      in-flight command and the formatted terminal result for a
      finished command.
- [ ] `get_command_result` with `wait_seconds=N` returns within
      ≤(N+1) seconds, returning the terminal result if the command
      finishes inside the window and the running snapshot otherwise.
- [ ] `list_commands` returns recent rows ordered by `started_at`
      descending, respects `machine` / `status` / `limit` / `since`,
      returns `"No commands found."` for an empty result.
- [ ] `list_commands` output has stable column alignment across all
      status values including `agent_disconnected`, verified by a
      snapshot test.
- [ ] An async command whose agent disconnects mid-flight ends up
      with status `agent_disconnected` and a populated `completed_at`
      in the audit DB, regardless of whether the connection process
      exited normally or abnormally.
- [ ] After a server restart, any audit row left at `running` from
      the previous boot is reconciled to `agent_disconnected` by the
      startup sweep before new agent connections are accepted.
- [ ] An async command's eventual reply produces the same formatted
      text (ignoring the prepended header block) as the equivalent
      sync `run_shell_command` would have, verified by diffing the
      result bodies for matching inputs.
- [ ] Multiple `get_command_result` callers waiting on the same id
      are all notified when the result arrives.
- [ ] A late agent reply to a command already marked
      `agent_disconnected` overwrites the audit row to the true
      terminal state and notifies waiters.
- [ ] Validation errors are returned as `isError: true` text with no
      crashes (unknown machine, unknown command_id, invalid status
      filter, malformed timestamps, non-integer numeric args,
      missing required args, unknown argument keys).
- [ ] Audit-DB write failures during async result handling do not
      crash the agent connection or affect other in-flight commands
      on the same connection.
- [ ] Audit-DB read failures during `get_command_result` or
      `list_commands` surface as `isError: true`, not as a handler
      crash.
- [ ] No regression in sync tool behavior (`run_shell_command`,
      `read_file`, `write_file`, `list_directory`, `check_agent_status`).
- [ ] `tools/list` advertises the three new tools with correct
      schemas including the maximum / minimum constraints and
      the enumerated `status` values for `list_commands`.
- [ ] Every code path enumerating command statuses includes
      `agent_disconnected` — verified by a grep test or equivalent.
- [ ] Registry supervisor entry and startup-sweep entry are ordered
      before the agent connection supervisor — verified by a
      supervision-tree inspection test.
- [ ] No agent-side changes required; the current Python agent binary
      works against the updated server unchanged.

### Outcome Signals (post-launch)

These are not implementation gates; they are the signals we use to
know async tools are actually delivering the intended value once the
work ships and operators start using it in real conversations.

- Claude-initiated `start_command` calls appear in real conversations
  at a meaningful rate relative to `run_shell_command`, confirming
  the LLM is choosing async for the workloads where it fits.
- Operators complete workflows that previously hit the 50-second
  ceiling (builds, test suites, migrations), end-to-end through
  mobile chat, without falling back to a terminal.
- The proportion of commands ending in `timeout` or `agent_disconnected`
  stays low enough that the failure modes feel like real infrastructure
  problems, not routine outcomes.
- Operator-reported friction around the sync/async split — "why did
  that time out, why did this not" — decreases, or at least does not
  increase, relative to baseline.

### Tests

Reuse the existing fake agent harness and the plug-test harness
already used for sync tools. Tests are grouped by the task unit they
primarily exercise so ownership is clear during implementation
review.

Unit 1 (async dispatch path):

- **Async reply writes audit row**: the fake agent receives an async
  `execute` and replies; the terminal row lands with the correct
  status and `completed_at`.
- **Sync and async in-flight coexist**: one sync and one async
  command dispatched to the same connection; both terminate
  correctly without cross-talk.
- **Concurrent async dispatch**: many async commands dispatched in
  quick succession to the same connection; all complete with
  correct status and no in-flight-map corruption.
- **Agent disconnect mid-async (normal exit)**: simulate the
  connection process terminating cleanly with an in-flight command;
  verify the audit row lands on `agent_disconnected` with
  `completed_at`.
- **Agent disconnect mid-async (abnormal exit)**: simulate the
  connection process crashing (raised exception, brutal kill); same
  outcome.
- **Audit-DB write failure on async reply**: inject a write error;
  connection process stays alive, error logged, other in-flight
  commands unaffected.

Unit 2 (registry subscription):

- **Subscribe then broadcast**: single subscriber receives the
  command-done notification.
- **Broadcast with no subscribers**: does not raise.
- **Multi-waiter**: two subscribers on one id both receive the
  message.
- **Subscriber crash before broadcast**: registry entries cleaned
  up; subsequent broadcast is a no-op.

Unit 3 (tool handlers):

- **`start_command` happy path**: dispatches to a connected fake agent,
  returns a `command_id`, audit row exists with status `running`.
- **`start_command` with disconnected machine**: returns `isError`
  with the "No agent '<name>' is connected." message, and no audit
  row is created (verified by an immediate `list_commands` filtered
  by that machine returning "No commands found.").
- **`start_command` with agent disconnecting between lookup and
  dispatch**: audit row transitions `running` → `agent_disconnected`,
  tool returns `isError`.
- **`start_command` with audit-DB insert failure**: tool returns
  `isError`, no frame is dispatched to the agent.
- **`get_command_result` while running**: returns the running snapshot
  with elapsed time.
- **`get_command_result` after completion**: returns the formatted
  terminal result identical to what sync would have produced.
- **`get_command_result` with wait_seconds**: blocks, then returns
  when the fake agent replies. Verify the `wait_seconds` upper clamp
  at 50 and rejection of negative / non-integer values.
- **`get_command_result` race**: command finishes between the initial
  audit lookup and subscription registration; result still surfaces.
- **`get_command_result` multi-waiter**: two callers waiting on the
  same id both receive the result.
- **`get_command_result` late-reply overwrite**: command already
  marked `agent_disconnected`; agent reply arrives after; final row
  reflects the reply's status and waiters still notified.
- **`get_command_result` deadline**: verify wall-clock overshoot is
  ≤1 second past `wait_seconds`.
- **`tools/list` schema**: verify the three tools appear with the
  declared arg schemas, enum values, and min/max constraints.

Unit 4 (audit query layer):

- **`list_commands` ordering, limit, filters**: each filter
  independently; empty-result message; invalid `status` rejection;
  malformed `since` rejection; multi-line command truncation;
  combined filters (e.g. `machine` + `status`).
- **"Get command by id" unknown id**: returns the "not found" shape
  the tool layer expects.
- **Audit DB unavailable**: both queries surface a structured error
  the tool layer turns into `isError: true`.

Cross-cutting:

- **Header-block formatting**: key order, line endings, trailing
  newlines are stable across runs (snapshot test for
  `start_command`, running `get_command_result`, terminal
  `get_command_result`).
- **Status-enumeration sweep**: a test (or build-time grep) that
  fails if `agent_disconnected` is missing from any status
  enumeration site.
- **Server restart sweep**: simulate a row left in `running` at
  application start; assert the startup sweep marks it
  `agent_disconnected` with a `completed_at`, before the agent
  connection supervisor accepts traffic.
- **Sync tool regression suite**: re-run the full SPEC-5 plug tests to
  confirm no behavior change.

### Validation

- The full automated test suite passes.
- Manual: from Claude.ai, dispatch a long-running command (such as
  one that sleeps two minutes then prints) via `start_command`, end
  the turn, in a follow-up turn call `get_command_result` with the
  returned id and confirm the formatted output is correct.
- Manual: dispatch the same command, `list_commands` to find it by
  recency, then `get_command_result` to see it.
- Manual: dispatch a command, kill the agent process locally,
  `get_command_result` and confirm the `agent_disconnected` message.
- Manual: dispatch a short command (something that prints and exits
  immediately) with `start_command` then immediately call
  `get_command_result` with `wait_seconds=2` and confirm it returns
  the terminal result inside the wait window.
- Manual: dispatch a long-running command, restart the server while
  it is still running, then `get_command_result` and confirm the
  row has been reconciled to `agent_disconnected` rather than
  hanging at `running`.
- Manual (mobile): run the full cross-turn flow from a phone —
  dispatch, background the chat, resume later, look up by id and by
  `list_commands` — to confirm the intended mobile-first UX works
  end to end, not just in a desktop session.

## Decisions

All blocking decisions resolved. The remaining items are defaults
locked in unless new information surfaces. Each resolution must be
reflected in both the code and the tests before the PR merges;
drift between spec text and behavior is what this section exists
to prevent.

1. **`start_command` against a disconnected machine — error vs.
   queue?** **Resolved: error immediately, no audit row.** The
   request never reached the agent, so it doesn't belong in the
   audit log. Callers who need a machine-status view use
   `check_agent_status`; callers who need a record of attempted-
   but-rejected dispatches need a different feature. Reflected in
   §`start_command` flow and the disconnected-machine test case.

2. **Should the running snapshot include process metadata
   (PID on the agent, etc.)?** No, not yet — the agent doesn't
   currently report it, and adding it requires an agent change.
   When partial output streaming lands, that's the right time to
   bundle process-state reporting in.

3. **Should `list_commands` include the originating tool
   (`run_shell_command` vs. `start_command`)?** Audit rows already
   store `type` (always `shell` today). If we want to distinguish
   sync vs. async lineage we'd need a new column or a convention.
   Defer until there's a concrete need.

4. **Should the audit row's `started_at` reflect the server's
   pre-dispatch time or the agent's actual process-start time?**
   Use server time at audit-insert; the agent doesn't report a
   start timestamp today, and relying on agent-local time would
   break `list_commands` ordering under clock skew. Revisit if
   agent timestamps become available.

5. **Should `list_commands` support pagination beyond `limit` +
   `since`?** The current shape lets callers walk back in time by
   passing a narrower `since`, which is sufficient for the
   conversational use case. A proper cursor-based pager is
   deferred until a caller needs to walk past 50 rows in one pass.

## Notes

- The `command_id` format is unchanged from sync (16-char URL-safe).
  This means a sync `run_shell_command` and an async `start_command`
  produce ids that look identical and live in the same audit table.
  That's intentional — it lets us collapse `list_commands` over both
  if we ever want to.
- The async path doesn't add any new failure modes that don't already
  exist in the sync path. Connection drops, agent crashes, command
  timeouts — all handled by the same code paths in the agent
  connection process.
- `wait_seconds` on `get_command_result` is the bridge between sync
  and async UX: it lets a caller dispatch async but treat short jobs
  synchronously without round-tripping. Useful when the caller doesn't
  know in advance how long something will take, and the main lever we
  have for making the sync/async split invisible to the operator.
- Output capture remains all-or-nothing per command for now. Streaming
  is the next obvious win and is its own spec because it touches the
  agent. Expect the streaming follow-up to be the first user-visible
  improvement on top of this work.
- Audit DB content is sensitive. Operators should treat it the same
  way they would treat shell history with output: it can contain
  tokens, secrets, and personal data. No new redaction is introduced
  here; this is a pre-existing property of the sync path that async
  inherits, made more consequential by the fact that results persist
  and are pulled later — possibly from a different device.

## Observations

- [decision] Three tools, not four — defer `cancel_command` until the
  agent gets a `cancel` frame, since killing the process group from
  the agent is the only correct cancellation
- [decision] No new wire frames — the existing `execute` / `result`
  protocol is sufficient because the change is purely in how the
  server treats the correlation, not what it sends
- [decision] Reuse the existing `commands` audit table rather than a
  separate `async_commands` table — async commands and sync commands
  are the same thing operationally, only the dispatch shape differs
- [decision] `wait_seconds` capped at 50 (the same Fly-proxy ceiling
  as sync tools) so a `get_command_result` call has the same
  reliability envelope as `run_shell_command`
- [decision] `list_commands` uses fixed-column text output rather
  than markdown tables so chat clients render it readably without
  table-aware parsers
- [decision] `agent_disconnected` is a terminal status, distinct from
  `failed`, so `list_commands` filtering is precise about why a
  command stopped
- [decision] `start_command` ordering is registry-lookup → audit-row
  insert → dispatch. Lookup first so a disconnected machine produces
  no audit row; insert before dispatch so a follow-up lookup by id
  is race-free; a lost dispatch is recoverable (sweep / terminate
  handler), a lost audit row is not
- [decision] Write-to-audit-DB precedes broadcast-to-registry on
  terminal transitions, so any subscriber that re-queries on wakeup
  always sees the final row
- [decision] Broadcast payload is opaque (carries only the command
  id); subscribers always re-read the audit row, so the DB remains
  the single source of truth even if the payload shape evolves
- [decision] Server restart sweeps every stale `running` row
  (sync- and async-dispatched alike) to `agent_disconnected` before
  the agent connection supervisor accepts traffic, so a deploy or
  crash never leaves an audit row hung indefinitely
- [decision] Terminal `get_command_result` header includes
  `started_at` as well as `duration`, so an operator reading a
  result later can correlate it with the originating conversation
  without a separate lookup
- [decision] Shared contracts (registry name, message shape, status
  literal, header key order, in-flight tag values) are agreed before
  unit work starts so Units 1–4 can proceed without integration-time
  conflicts
- [pattern] Per-command registry subscriptions for `wait_seconds`
  follows the existing supervised-process / registry pattern from
  SPEC-3 — one less thing to invent
- [pattern] Audit DB as the durable result store, in-memory state as
  the live coordination layer — same split SPEC-1 establishes for
  the sync path
- [risk] No partial output capture means `get_command_result` on a
  running long command shows no useful progress information; this is
  acceptable for the first cut but limits the UX value for slow jobs
  with informative stdout — output streaming is the natural follow-up
- [risk] If a future change adds a `cancel` frame, the audit lifecycle
  will need a `cancelled` terminal state; account for it in any code
  that switches on terminal vs. running so the change stays additive
- [risk] SQLite write contention is unchanged from the sync path, but
  if `list_commands` becomes a hot read while many async commands are
  running, consider an index on `started_at` and `(machine,
  started_at)` — the existing schema doesn't have these
- [risk] A late agent reply arriving after `agent_disconnected` has
  been recorded must overwrite, not skip — otherwise the authoritative
  result is lost to a transient connection flap
- [risk] Audit-DB write failures during async result handling must
  not crash the agent connection; isolate the write so a disk-full
  or SQLite-busy situation doesn't take down all in-flight commands
  on that connection
- [risk] Connection-process abnormal exit (brutal kill, raised
  exception) must still mark in-flight async rows
  `agent_disconnected`; relying solely on the standard
  process-termination callback is insufficient — use a monitor or
  equivalent
- [risk] Registry must start before the connection supervisor in the
  application tree, or early-arriving replies will fail to broadcast
- [risk] Server restart silently wipes in-flight tracking; without
  the startup sweep, the audit DB drifts from reality each deploy.
  Sweep ordering relative to the connection supervisor must be
  enforced and tested, not assumed
- [risk] Audit DB has no retention policy. Async unblocks longer
  workloads, which means more rows per day; growth pressure on the
  audit DB will reach operators sooner than it would have with sync
  alone. Track this so it can be addressed in a separate operational
  spec before it becomes a problem
- [risk] Adding `agent_disconnected` to the status enum is an
  audit-wide change; missing a single enumeration site will silently
  reject valid rows or filters, so the sweep must be verified by a
  test, not just a manual grep
- [risk] Audit DB stores command output verbatim, including any
  secrets that leak into stdout/stderr or argv; async makes this
  more visible because results are pulled later, possibly from a
  different device. Document this for operators; don't paper over it
- [risk] Sync and async produce indistinguishable ids and share a
  table; an operator debugging a stuck command cannot tell from
  `list_commands` alone whether it was dispatched sync or async.
  Acceptable for the first cut (both lifecycles are the same), but
  worth revisiting if operators start asking
- [constraint] The Fly proxy 60s per-request cap continues to govern
  every synchronous call including `get_command_result` with
  `wait_seconds`; cap stays at 50 with 5s slack
- [constraint] No agent-side changes — the Python agent must keep
  working untouched
- [constraint] Server clock (not agent clock) supplies all timestamps
  in the audit row, so `list_commands` ordering is immune to agent
  clock skew

---
title: 'SPEC-4: Command Dispatch and Result Correlation'
type: spec
permalink: specs/spec-4-command-dispatch-and-result-correlation
tags:
- dispatch
- correlation
- genserver
- core
---

# SPEC-4: Command Dispatch and Result Correlation

## Why

This is the core architectural fix that motivates the entire port. The Python server's `execute_command` function inserts a row into SQLite, sends the command over the WebSocket, then **polls the database every 500ms** waiting for the agent's result to land as a row update. That pattern is the direct cause of several stability problems:

1. Two sources of truth (WebSocket and SQLite) for the same command state.
2. 500ms of wasted latency per command, every time.
3. No clean cancellation path — a polling loop can't be notified of a disconnect.
4. If the WebSocket delivers the result but the database write fails, the caller hangs until timeout.

BEAM's answer is straightforward: the GenServer that owns the socket also owns a map of `command_id => from`. When a caller invokes `GenServer.call`, we stash the `from` in the map and don't reply yet. When the agent's `result` frame arrives, we look up the `from` by `command_id` and reply directly. The caller unblocks the instant the bytes arrive. No polling. No database in the request path. No cancellation ambiguity.

## What

**In scope:**

- `ExCodeRemote.Commands.Dispatcher` — the public entry point used by MCP tool handlers
- `ExCodeRemote.Agent.Connection.dispatch/3` — synchronous send-and-wait primitive on the Connection GenServer
- Pending-command state on the Connection GenServer (a map of command ID to the caller's `from` reference)
- Command ID generation (URL-safe random, server-side)
- Timeout handling — both the caller timeout and the command's own `timeout` field
- Cancellation on agent disconnect — all pending callers receive `{:error, :agent_disconnected}` when the Connection terminates
- A `FakeAgent` test helper for use here and in future specs

**Out of scope:**

- MCP tool handlers calling `Dispatcher.run/2` (SPEC-5)
- Audit writes (SPEC-6 — but the dispatcher emits telemetry hooks that the audit module will subscribe to later)
- Retries — the dispatcher does not retry; failed dispatches surface as errors to the caller

## How (High Level)

### Public API

The `ExCodeRemote.Commands.Dispatcher` module exposes a single function: `run(machine, command)`. The command map contains a `type` (one of `:shell`, `:read_file`, `:write_file`, `:list_dir`), along with optional fields like `command`, `path`, `content`, `working_dir`, and `timeout`.

The return value is either `{:ok, result}` where result contains `status`, `output`, `error`, and `exit_code`, or `{:error, reason}` where reason is `:not_connected`, `:timeout`, or `:agent_disconnected`.

### Dispatcher Flow

The dispatcher is a pure module (no process of its own). It:

1. Resolves the machine name via Agent.Registry to find the Connection PID, or returns `{:error, :not_connected}`.
2. Generates a URL-safe random command ID.
3. Calls `Agent.Connection.dispatch(pid, command_id, command)` as a GenServer.call with a timeout of `command.timeout + 5` seconds (5s slack for round-trip overhead).
4. Returns the result or translates the error.

### Connection GenServer Changes

The Connection's `:pending` map (introduced as a stub in SPEC-3) becomes load-bearing:

**On dispatch call:** The Connection builds an `execute` frame from the command, sends it to the Socket process for transmission, stores the caller's `from` reference keyed by `command_id`, and returns `:noreply` — the caller blocks.

**On result frame:** When the Socket forwards a `result` frame, the Connection looks up the command ID in the pending map. If found, it pops the entry, builds a result map from the frame's fields, and calls `GenServer.reply/2` to unblock the waiting caller. If the ID is unknown (late arrival, duplicate), it is silently ignored.

### Cancellation on Disconnect

When the Connection GenServer terminates (normal or crash), its `terminate/2` callback iterates over all entries in the pending map and replies with `{:error, :agent_disconnected}` to each. This ensures no caller can hang past a dropped connection.

### Command ID Generation

Command IDs are generated server-side using 12 bytes of cryptographic randomness, base64url-encoded. The agent never generates IDs — it just echoes the string from `execute` into `result`.

### Telemetry Hooks

The dispatcher emits two telemetry events that SPEC-6 and SPEC-7 will subscribe to:

- `[:ex_code_remote, :dispatcher, :command, :start]` — with system time and metadata containing machine name, command ID, and command type.
- `[:ex_code_remote, :dispatcher, :command, :stop]` — with duration and metadata containing machine name, command ID, command type, and final status.

These are hooks, not business logic. The dispatcher works without any subscribers.

## How to Evaluate

### Success Criteria

- [ ] `Dispatcher.run/2` returns `{:error, :not_connected}` for unknown machines
- [ ] `Dispatcher.run/2` against a connected agent sends an `execute` frame and blocks until the matching `result` arrives
- [ ] Round-trip latency for a no-op command is under 10ms in tests (compared to 500ms minimum in the Python version)
- [ ] Pending callers are unblocked with `{:error, :agent_disconnected}` when the Connection terminates
- [ ] Unknown/duplicate result IDs are silently ignored
- [ ] Caller timeout is respected and exceeds `command.timeout` by at least 5s of slack
- [ ] Telemetry `:start` and `:stop` events are emitted

### Tests

Tests should be included with the implementation changes. This spec also introduces a **FakeAgent** test helper — a small module that connects to the server via a WebSocket client, registers under a given machine name, and handles incoming `execute` frames with a configurable response function. This helper is reused in SPEC-5 and beyond.

- **Dispatcher against unknown machine** returns `{:error, :not_connected}`.
- **Dispatcher against a connected FakeAgent** that echoes a `completed` result returns `{:ok, result}` with expected fields.
- **Round-trip latency** is under 10ms (using timer measurement).
- **Telemetry events** `:start` and `:stop` are captured in order with matching command IDs.
- **Connection terminate with pending callers** — all callers receive `{:error, :agent_disconnected}`.
- **Unknown result ID** — `handle_cast` with an unrecognized ID does not crash or affect pending state.

### Validation

- `mix test` passes
- Manual: with the Python agent connected, use an IEx session to call `Dispatcher.run/2` with a shell command and observe the result immediately

## Notes

- The biggest risk in this spec is a subtle leak in the pending map: if a result arrives for a caller that has already timed out, the entry should be cleaned up. `GenServer.reply/2` on a dead caller is a silent no-op, and `Map.pop` in both paths prevents the leak, but it's worth a dedicated test case.
- Telemetry is a standalone library included by most Elixir projects. If it's not pulled in transitively, add it to deps.
- SPEC-5 (MCP tools) is the first caller of `Dispatcher.run/2`, so the public API must be stable before that spec is written.

## Observations

- [decision] In-memory `command_id => from` map on the owning Connection GenServer — the canonical BEAM pattern for request/response over a long-lived socket
- [decision] Dispatcher is a plain module, not a process — no bottleneck, no mailbox contention, and the Connection is the only stateful actor
- [decision] Server generates command IDs, agent echoes them — agent remains dumb, wire format matches existing Python agent
- [decision] Disconnect cancels pending callers via `terminate/2` — no caller can hang past a dropped connection
- [decision] Telemetry events are emitted as hooks, consumers decided later — dispatcher has no runtime dependency on audit or metrics
- [anti-pattern] Polling a database for state the WebSocket already delivered — this is the Python version's core bug, specifically not reproduced

---
title: 'SPEC-6: Audit Log'
type: spec
permalink: specs/spec-6-audit-log
tags:
- audit
- persistence
- ecto
- sqlite
---

# SPEC-6: Audit Log

## Why

The Python server uses SQLite as both an audit log and a request/response queue. SPEC-4 killed the request/response role — correlation is in-memory. This spec restores the **audit** role as an independent, write-only concern that never touches the request path.

Audit is useful for: debugging, support ("did Claude run anything weird on my machine yesterday?"), and correlating server logs with agent-side events. It should never be able to slow down or break a command dispatch.

## What

**In scope:**

- `ExCodeRemote.Audit` — the writer module, subscribed to dispatcher telemetry events
- Ecto schema and migration for a `commands` table
- `exqlite` / `ecto_sqlite3` adapter
- `Audit.Repo` as a supervised process in the application tree
- `GET /commands` debug endpoint (bearer-token auth) that returns the most recent N commands as JSON
- A well-defined failure mode: if the audit write fails, the dispatch still succeeds, but an error is logged

**Out of scope:**

- Log retention or cleanup (deferred; will revisit when it matters)
- Audit of agent connect/disconnect events (possible later, not needed now)
- Structured query or filter endpoints — `/commands?limit=N` is enough for debugging
- Replacing Ecto with a lower-overhead option — start with the boring choice

## How (High Level)

### Dependencies

Add Ecto SQL (`~> 3.12`) and ecto_sqlite3 (`~> 0.17`) to deps.

### Schema

A `commands` table with columns: `id` (string primary key, matches the command ID from the dispatcher), `machine`, `type`, `status`, `command`, `path`, `working_dir`, `timeout`, `output`, `error`, `exit_code`, `duration_ms`, `started_at`, and `completed_at`.

The `content` field (for `write_file`) is deliberately **not** stored. Writing large file bodies to the audit log is not worth the disk cost; the `path` is enough for forensic purposes.

Indexes on `status`, `(machine, started_at DESC)`, and `(started_at DESC)`.

### Audit Writer

`ExCodeRemote.Audit` attaches to the dispatcher's telemetry events from SPEC-4:

- On the `:start` event, it inserts a row with `status: "running"` and the command metadata.
- On the `:stop` event, it updates the row with the final status, duration, and completion timestamp.

The writer runs each database operation asynchronously via a Task.Supervisor so the dispatcher is never blocked on disk I/O. Each handler is wrapped in error rescue — if the Repo is down or the write fails, it logs an error but never propagates the exception to the dispatcher's process.

**Crucial invariant:** the audit writer must never raise back into the dispatcher's process. The async task and rescue clauses guarantee that.

### Supervision

The application supervisor gains two new children: the `Audit.Repo` (Ecto repository) and an `Audit.TaskSupervisor` for the async write tasks. The telemetry attachment is called at application start.

### Debug Endpoint

A `GET /commands` route in the router, authenticated via bearer token (same `AUTH_TOKEN` env var used by the WebSocket). Returns the most recent N rows as JSON, ordered by `started_at` descending. Accepts an optional `limit` query param (default 20). This is an operator-only debug endpoint — a single shared secret is fine.

### Config

The Repo is configured in `runtime.exs` with the database path from the `DATABASE_PATH` env var (default `priv/data/audit.db`), a pool size of 5, and WAL journal mode for concurrent reads while writes are in progress.

## How to Evaluate

### Success Criteria

- [ ] `mix ecto.create && mix ecto.migrate` creates the `commands` table
- [ ] `Audit.Repo` is started by the application supervisor
- [ ] Dispatching a command produces an audit row with `status: "running"` then updated to the final status
- [ ] Audit writer failure (e.g. Repo down) produces a log line but does **not** fail the dispatch
- [ ] `GET /commands` returns JSON of the most recent commands, newest first
- [ ] `GET /commands` without a valid bearer token returns `401`
- [ ] Round-trip latency for a no-op command remains under 10ms (audit is not in the request path)

### Tests

Tests should be included with the implementation changes:

- **Schema roundtrip**: insert a Command record, fetch it, assert fields match.
- **Dispatch produces audit row**: dispatch a command via FakeAgent, allow async tasks to flush, assert exactly one audit row exists with the correct status and non-negative duration.
- **Audit failure isolation**: simulate a Repo failure (e.g. stop the Repo process), dispatch a command, assert the dispatch still returns `{:ok, _}` and an error log line is emitted.
- **Latency**: round-trip dispatch with audit attached remains under 10ms.
- **Debug endpoint auth**: `GET /commands` without auth returns 401, with valid auth returns 200 and a JSON array.
- **Debug endpoint ordering**: returned rows are in descending `started_at` order, and `limit` param is respected.

### Validation

- `mix test` passes
- Manual: connect an agent, run a few shell commands via MCP, hit `/commands` with the auth token, verify rows appear with correct fields

## Notes

- Storing the `content` field for `write_file` would blow up the DB on anything non-trivial. We record `path` and `type`; if you need to reconstruct the write, look at the client-side chat history.
- The debug endpoint is intentionally minimal. Anything richer (filters, pagination, search) should wait until there's a concrete user complaint.
- If the audit log ever becomes a hotspot, the Task.Supervisor fan-out can be replaced with a batching writer GenServer. Not needed at expected volumes.

## Observations

- [decision] Ecto + SQLite + WAL — boring, proven, zero ops overhead, single-file backup story
- [decision] Audit writer subscribes to telemetry events emitted by the dispatcher — zero coupling in the hot path
- [decision] Async writes via Task.Supervisor — audit latency is invisible to the dispatcher
- [decision] `content` field deliberately not stored — audit should not become a blob store
- [decision] `/commands` debug endpoint reuses `AUTH_TOKEN` — not worth a separate secret for an operator-only endpoint
- [invariant] Audit writer failures must never propagate to the dispatcher — enforced by rescue + async task
- [pattern] Telemetry events from SPEC-4 are the integration surface — not a direct call from the dispatcher

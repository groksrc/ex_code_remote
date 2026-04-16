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

Status: Implemented

## Why

The Python server uses SQLite as both an audit log and a request/response queue. SPEC-4 killed the request/response role — correlation is in-memory. This spec restores the **audit** role as an independent, write-only concern that never touches the request path.

Audit is useful for: debugging, support ("did Claude run anything weird on my machine yesterday?"), and correlating server logs with agent-side events. It should never be able to slow down or break a command dispatch.

**Customer value:** When an operator or end user needs to answer "what happened on my machine?", today the answer is buried in ephemeral logs or lost entirely. This spec creates a durable, queryable record of every command dispatched through the system. The primary beneficiary is the operator debugging a production incident or responding to a user's support question — they get a single endpoint that shows exactly what ran, when, on which machine, and whether it succeeded. Secondary beneficiaries are developers during local iteration who need to verify their agent is dispatching the expected commands.

## What

**Dependencies:** SPEC-4 (dispatcher with telemetry events) must be complete before this work begins. The audit writer subscribes to the dispatcher's telemetry events defined in SPEC-4 — specifically `:start` and `:stop` events. SPEC-5 (MCP tools) should ideally be complete so end-to-end audit testing is possible, but is not strictly required since the audit writer subscribes to dispatcher events regardless of what triggers them.

**Integration points with other specs:**

- **SPEC-4 (Dispatcher):** The audit writer consumes telemetry events emitted by the dispatcher. The telemetry metadata contract defined below must match what SPEC-4 actually emits. The implementer must verify the metadata shape against SPEC-4's implementation before writing the audit handler — if the shapes diverge, update either this spec or SPEC-4 to reconcile them before proceeding.
- **SPEC-5 (MCP Tools):** The `type` column values correspond to MCP tool names defined in SPEC-5. The audit writer does not depend on SPEC-5 code, but the `type` values must be consistent. If SPEC-5 adds new tool types, the audit writer handles them automatically since it reads the type from telemetry metadata rather than hardcoding allowed values.
- **SPEC-8 (Deployment):** The `exqlite` NIF requires build-time C compiler support in the Dockerfile. The production database path (`DATABASE_PATH` env var) must point to the Fly.io persistent volume. These requirements must be reflected in SPEC-8's Dockerfile and deployment configuration.
- **Router/Auth:** The debug endpoint reuses the same bearer-token authentication mechanism used by other authenticated endpoints (WebSocket upgrade, any SPEC-5 endpoints). The implementer must identify the existing auth plug or function and reuse it rather than reimplementing token comparison.

**In scope:**

- `ExCodeRemote.Audit` — the writer module, subscribed to dispatcher telemetry events from SPEC-4
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

Add Ecto SQL and ecto_sqlite3 to deps. Verify that the chosen versions are compatible with each other and with the project's existing Elixir/OTP version before adding them.

### Schema

A `commands` table with columns: `id` (string primary key, matches the command ID from the dispatcher), `machine`, `type`, `status`, `command`, `path`, `working_dir`, `timeout`, `output`, `error`, `exit_code`, `duration_ms`, `started_at`, and `completed_at`.

The `id` is not auto-generated — it is the same correlation ID assigned by the dispatcher in SPEC-4 and passed through telemetry metadata. The schema should use a string primary key with autogenerate disabled so that the audit row is keyed to the dispatcher's own ID.

**Column types and nullability:**

- `id` — string, primary key, not null
- `machine` — string, not null
- `type` — string, not null (e.g. `"run_shell_command"`, `"write_file"`, `"read_file"`, `"list_directory"`)
- `status` — string, not null (one of `"running"`, `"completed"`, `"failed"`, `"timed_out"`)
- `command` — string, nullable (only populated for `run_shell_command`)
- `path` — string, nullable (populated for file and directory operations, null for shell commands that do not target a specific path)
- `working_dir` — string, nullable (populated for `run_shell_command`, may be null for other types)
- `timeout` — integer, nullable (the timeout value in milliseconds as provided in the command request)
- `output` — text, nullable (stdout for shell commands, result text for other command types)
- `error` — text, nullable (stderr for shell commands, error message for failures)
- `exit_code` — integer, nullable (only meaningful for shell commands)
- `duration_ms` — integer, nullable (null while status is `"running"`, computed from telemetry stop measurement)
- `started_at` — utc_datetime, not null
- `completed_at` — utc_datetime, nullable (null while status is `"running"`)

**Column semantics:**

- `type` — the command type string as defined by the MCP tool that originated it. This value comes from the telemetry event metadata.
- `status` — one of `"running"` (set on start), `"completed"` (command succeeded), `"failed"` (command returned an error), or `"timed_out"` (command exceeded its timeout). The final status is determined by the stop event metadata.
- `command` — the shell command string for `run_shell_command`, or null for non-shell command types. Do not overload this column to store other command-type-specific data.
- `output` and `error` — the stdout and stderr strings respectively. For non-shell commands, `output` holds the tool's result text if applicable and `error` holds any error message.
- `duration_ms` — integer, computed from the telemetry stop event's measurement duration. Null while status is `"running"`.
- `started_at` and `completed_at` — UTC timestamps. `completed_at` is null while status is `"running"`.

The `content` field (for `write_file`) is deliberately **not** stored. Writing large file bodies to the audit log is not worth the disk cost; the `path` is enough for forensic purposes.

Indexes on `status`, `(machine, started_at DESC)`, and `(started_at DESC)`.

### Telemetry Metadata Contract

The audit writer depends on a specific set of fields being present in the telemetry event metadata emitted by the dispatcher in SPEC-4. The SPEC-4 implementation must provide at minimum: `id`, `machine`, `type`, `command`, `path`, `working_dir`, and `timeout` on the start event, and additionally `status`, `output`, `error`, `exit_code`, and `duration_ms` on the stop event. If SPEC-4's telemetry metadata shape changes, the audit writer must be updated to match. This contract should be documented in SPEC-4 as well so both sides stay in sync.

The stop event must also carry the `started_at` timestamp so the upsert path can produce a complete row. The implementer must verify this field is present in SPEC-4's stop event metadata.

**Metadata field handling:** The audit writer must handle missing or unexpected metadata fields defensively. If a metadata field is absent (for example, `command` is not present for a `read_file` operation), the writer should insert null for that column rather than crashing. This is important because future command types may not provide all fields, and the writer should not break when new tool types are added.

**Telemetry measurement for duration:** The stop event's measurements map contains a duration key with the elapsed time in native time units (as per the telemetry library convention). The audit writer must convert this to milliseconds using the appropriate system time conversion before storing it in `duration_ms`. If SPEC-4 already provides a pre-computed `duration_ms` in the metadata, the writer should use that instead and this conversion is not needed — the implementer must check which approach SPEC-4 uses.

### Audit Writer

The audit writer module attaches to the dispatcher's telemetry events defined in SPEC-4:

- On the command start event, it inserts a row with status "running" and the command metadata.
- On the command stop event, it updates the row with the final status, duration, and completion timestamp.

The writer runs each database operation asynchronously via a Task.Supervisor so the dispatcher is never blocked on disk I/O. Each handler is wrapped in error rescue — if the Repo is down or the write fails, it logs an error but never propagates the exception to the dispatcher's process.

**Crucial invariant:** the audit writer must never raise back into the dispatcher's process. The async task and rescue clauses guarantee that.

**Telemetry handler detachment:** If a telemetry handler raises an exception, the telemetry library silently detaches it and it will no longer receive events for the remainder of the application's lifetime. The rescue clause inside the handler function prevents this, but as a defense-in-depth measure, the application should log a warning if a handler is unexpectedly detached. Consider checking handler attachment status periodically or re-attaching on failure, though the rescue clause should make detachment impossible in practice.

**Ordering guarantee for start/stop writes:** Because both the start insert and the stop update are dispatched as async tasks, there is a race condition: the stop update task could execute before the start insert task completes, causing the update to find no row. The implementation must handle this. The recommended approach is to have the stop handler use an upsert (insert-or-update) rather than a plain update — if the row does not yet exist, insert the full row with the final status directly; if it does exist, update it. This way, regardless of task execution order, the final state is correct. An alternative is to serialize start and stop writes through a single process, but the upsert approach is simpler and preserves the fully-async design. Whichever approach is chosen, the test suite must include a test that verifies correctness when the stop event is processed before the start event's write has committed.

**Upsert field completeness:** When the stop handler performs an upsert because the start row does not yet exist, the inserted row must contain all fields from both the start and stop events — including `machine`, `type`, `command`, `path`, `working_dir`, `timeout`, `started_at`, and the stop-specific fields like `status`, `output`, `error`, `exit_code`, `duration_ms`, and `completed_at`. This means the stop telemetry event metadata must carry enough information to populate the full row, or the stop handler must have access to the original start metadata. The implementer must verify that SPEC-4's stop event includes all the fields from the start event in addition to the stop-specific fields. If it does not, coordinate with SPEC-4 to add them, or cache the start metadata in-process before dispatching the async task.

### Graceful Shutdown

On application shutdown, in-flight async write tasks in the Audit.TaskSupervisor should be allowed to complete rather than being killed immediately. The TaskSupervisor's shutdown configuration should allow a brief grace period (e.g., five seconds) for running tasks to finish before the supervisor terminates them. This prevents audit rows from being silently lost during deploys or restarts. The grace period does not need to be long — audit writes to a local SQLite file are fast — but it must be non-zero so that writes already in progress can commit.

### Supervision

The application supervisor gains two new children: the Audit.Repo (Ecto repository) and an Audit.TaskSupervisor for the async write tasks. Both should be started before Bandit in the supervision tree, and before the telemetry handlers are attached, so that the Repo is accepting queries before any events can fire. The telemetry attachment is called at application start, after the Repo and TaskSupervisor are confirmed running.

**Supervision strategy:** The Audit.TaskSupervisor should use a one-for-one strategy with a reasonable max_children limit to prevent unbounded task spawning under pathological conditions (e.g., a flood of commands while the database is slow). A limit of 100 concurrent tasks is a reasonable starting point. If the limit is reached, the audit writer should log a warning and drop the write rather than blocking. Hitting this limit persistently is a signal that the database is unhealthy or the volume is full — the warning log should be phrased to help an operator diagnose the root cause.

### Debug Endpoint

A GET /commands route in the router, authenticated via bearer token (same AUTH_TOKEN env var used by the WebSocket). The bearer-token check should reuse the same authentication plug or function used by other authenticated endpoints in the router rather than reimplementing token comparison inline. Returns the most recent N rows as JSON, ordered by started_at descending. Accepts an optional `limit` query param (default 20, capped at a maximum of 100 to prevent accidental full-table dumps). This is an operator-only debug endpoint — a single shared secret is fine.

**Query param validation:** If the `limit` query param is present but not a valid positive integer (e.g., `limit=abc` or `limit=-5`), the endpoint should ignore the invalid value and use the default of 20 rather than returning a 400 error. This keeps the endpoint simple and forgiving for operator use.

**Machine filter:** The endpoint should accept an optional `machine` query param to filter results by machine name. This is a minimal addition that significantly improves debugging when multiple agents are connected. If not provided, return commands from all machines.

The JSON response shape should be a top-level object with a `"commands"` key containing the array, not a bare array. This leaves room for adding metadata (like total count) later without a breaking change. Each command object should include all stored columns with keys matching the schema column names. Timestamp fields should be serialized as ISO 8601 strings. Null values should be included as JSON `null` rather than omitted, so the response shape is consistent regardless of command type or status.

**Endpoint availability when audit is degraded:** If the Repo failed to start or auto-migration failed (see the Migrations section on graceful degradation), the debug endpoint should return a 503 status with a JSON body indicating the audit system is unavailable, rather than crashing with a 500. This gives operators a clear signal about the state of the audit subsystem.

### Config

The Repo is configured in runtime.exs:

- **Dev/test:** database path defaults to priv/data/audit.db (relative to project root). The priv/data/ directory should be added to .gitignore since it contains local runtime state.
- **Prod:** reads DATABASE_PATH env var, defaulting to /data/audit.db (the Fly.io volume mount from SPEC-8)
- Pool size of 1 for writes. SQLite only permits one concurrent writer even in WAL mode, so a write pool larger than 1 provides no benefit and can cause busy/locked errors under contention. If future needs require concurrent read queries (e.g. a more sophisticated debug endpoint), a separate read-only Repo with a small pool can be added at that time. WAL journal mode should be enabled for concurrent reads while writes are in progress.

**SQLite PRAGMA configuration:** In addition to WAL mode, the following PRAGMAs should be set on connection: busy_timeout set to 2000 milliseconds (to handle brief lock contention from the async writer rather than immediately returning SQLITE_BUSY), and journal_size_limit set to a reasonable value (e.g., 64 MB) to prevent unbounded WAL file growth. These can be set via the after_connect callback in the Repo configuration.

### Migrations

Migrations should be created using the standard Ecto migration generator and run via the standard migration command. The migration must specify the Audit.Repo explicitly since the application may eventually have more than one Repo. On first startup in a new environment (fresh deploy, new dev checkout), the database must be created before migrations can run — document this in the project README or setup instructions. Consider whether the application should auto-create and auto-migrate the database at startup (common for SQLite-backed apps since there is no shared database server to coordinate with) and if so, add the appropriate logic to the application start callback.

**Recommendation on auto-migration:** For a SQLite-backed application with a single-file database, auto-creating and auto-migrating at startup is the pragmatic choice. It eliminates a manual step for every deploy and every new dev checkout. Implement this in the application start callback, after the Repo is started but before telemetry handlers are attached. Log the migration activity at info level so it is visible in deploy logs. If the migration fails (e.g., corrupted database file), the application should log the error and continue starting without the audit system rather than crashing the entire application — audit is a non-critical subsystem. In this degraded mode, the telemetry handlers should not be attached (since writes would fail anyway), and the debug endpoint should return a 503 indicating the audit system is unavailable.

### Build and Runtime Dependencies

The exqlite NIF requires a C compiler and SQLite development headers at build time. At runtime, the compiled NIF includes a statically-linked SQLite, so no shared library is needed on the runtime image. The SPEC-8 Dockerfile must include a C compiler and build-essential packages in the build stage; the runtime stage does not need them. Verify this works in the SPEC-8 Docker build — if the NIF compilation fails, the entire release build fails.

### Test Setup

Tests that hit the Repo need a database. Use the Ecto SQL sandbox in test mode so each test gets an isolated transaction that rolls back after the test completes. The test config should point the Repo at a test-specific database path. Migrations must run before the test suite — add a test support module that sets up the sandbox checkout.

**SQLite sandbox caveat:** The ecto_sqlite3 adapter's sandbox support has limitations compared to Postgres — in particular, SQLite does not support concurrent transactions in the same way, so sandbox mode effectively serializes all database access within a test. This is fine for this use case since audit tests are not performance-sensitive, but tests must not rely on true concurrent transaction isolation. If sandbox mode proves problematic with ecto_sqlite3, an acceptable fallback is to use a dedicated test database file that is deleted and recreated before each test run, accepting the slower teardown.

**Flushing async writes in tests:** Because the audit writer dispatches work through Task.Supervisor, tests that assert on audit rows after dispatching a command must explicitly wait for the async tasks to complete. The recommended approach is to poll the task supervisor children list and wait until it is empty, or use a helper that polls the Repo for the expected row with a short timeout. Do not use arbitrary sleep calls — they are flaky and slow. Document the chosen flush mechanism so all audit tests use it consistently.

**Test helper module:** Create a shared test helper that provides: a flush function implementing the chosen flush mechanism, and metadata builder functions that construct valid telemetry metadata maps with sensible defaults and allow overrides. This prevents each test from hand-building metadata maps and ensures consistency with the telemetry contract.

**Dispatching commands in tests:** Several tests require dispatching a command to trigger audit events. For audit tests, the simplest approach is to emit telemetry events directly with the correct event names and metadata maps — this tests the audit writer in isolation without requiring a WebSocket agent or the full dispatcher stack. The test helper's metadata builder functions support this pattern. For the end-to-end manual validation, a real agent connection is used, but automated tests should not depend on one.

## Task Breakdown

The following tasks can be used to decompose this work. Tasks within the same group have no dependencies on each other and can be worked in parallel. Tasks in later groups depend on earlier groups being complete.

**Group 1 — Foundation (no internal dependencies):**

- **Task 1A: Add dependencies and configure Repo.** Add ecto_sql and ecto_sqlite3 to mix.exs. Create the Audit.Repo module. Add Repo configuration to config files with the database paths, pool size, and PRAGMA settings described above. Add priv/data/ to .gitignore.
- **Task 1B: Create schema and migration.** Create the Ecto migration for the commands table with all columns, types, nullability constraints, and indexes as specified. Create the Audit.Command schema module with the field definitions and primary key configuration.

**Group 2 — Core logic (depends on Group 1):**

- **Task 2A: Audit writer and supervision.** Create the audit writer module with telemetry handler attachment, start/stop event handling, upsert logic, async task dispatch, and error rescue. Add Audit.Repo, Audit.TaskSupervisor, and telemetry attachment to the application supervision tree in the correct order. Implement auto-migration logic in the application start callback. Configure graceful shutdown for the TaskSupervisor.
- **Task 2B: Debug endpoint.** Add the GET /commands route to the router with bearer-token authentication (reusing the existing auth mechanism), query param parsing for limit and machine, the response envelope, JSON serialization, and 503 handling for degraded audit state. This task requires the schema from Task 1B and a running Repo — the Repo supervision from Task 2A must be in place, but the audit writer logic is not needed since the endpoint can be tested by inserting rows directly.

**Group 3 — Test suite (depends on Groups 1 and 2):**

- **Task 3A: Test infrastructure.** Create the test helper module with flush mechanism, metadata builders, and sandbox or database setup. Create the RepoCase module for test setup.
- **Task 3B: Write all tests.** Implement the full test suite as described in the Tests section below. Depends on Task 3A for test infrastructure and Tasks 2A/2B for the modules under test.

## How to Evaluate

### Success Criteria

- [ ] Database creation and migration produces the commands table with all specified columns, types, nullability constraints, and indexes
- [ ] Audit.Repo is started by the application supervisor and is accepting queries before Bandit starts
- [ ] The Audit.TaskSupervisor is started and configured with a max children limit
- [ ] Telemetry handlers are attached after the Repo and TaskSupervisor are confirmed running
- [ ] Dispatching a command produces an audit row with status "running" then updated to the final status
- [ ] When the stop event is processed before the start insert completes, the audit row still ends up with the correct final state, including all fields from both events
- [ ] Audit writer failure (e.g. Repo down) produces a log line but does **not** fail the dispatch
- [ ] Audit writer failure does **not** cause telemetry handler detachment
- [ ] Missing or unexpected metadata fields in telemetry events do not crash the audit writer
- [ ] GET /commands returns JSON of the most recent commands, newest first, wrapped in a {"commands": [...]} envelope
- [ ] GET /commands without a valid bearer token returns 401
- [ ] GET /commands?limit=N respects the limit, and values above 100 are capped to 100
- [ ] GET /commands?limit=abc uses the default limit of 20
- [ ] GET /commands?machine=X filters results to the specified machine
- [ ] Null fields are serialized as JSON null, not omitted from the response
- [ ] Timestamps in the JSON response are ISO 8601 formatted strings
- [ ] Round-trip latency for a no-op shell command remains under 10ms with the audit writer attached — confirming audit is not in the request path. This is validated manually, not as an automated test.
- [ ] WAL mode and configured PRAGMAs are active on the database connection
- [ ] Auto-migration runs successfully on first startup with no pre-existing database
- [ ] When auto-migration fails, the application starts without the audit system and the debug endpoint returns 503
- [ ] On graceful shutdown, in-flight audit write tasks are given time to complete before the supervisor terminates

### Tests

Tests should be included with the implementation changes:

- **Schema roundtrip**: insert a Command record, fetch it, assert fields match including that the id is the caller-supplied string, not an auto-generated value. Verify that null fields are correctly stored and retrieved.
- **Dispatch produces audit row**: emit telemetry events matching the dispatcher's event names with valid metadata, flush async audit tasks using the chosen flush mechanism, assert exactly one audit row exists with the correct status and non-negative duration.
- **Stop-before-start race**: emit a stop telemetry event before the start event's async write has committed (e.g., by emitting both events in quick succession or by mocking the insert to add a delay), and assert that the final audit row has the correct completed state with all fields populated — including fields that would normally only be set on the start event (machine, type, command, path, working_dir, timeout, started_at).
- **Audit failure isolation**: simulate a Repo failure (e.g. stop the Repo process temporarily, accounting for supervisor restart behavior — the test may need to either stop the supervisor itself or use a mock that returns errors), emit telemetry events, assert the dispatch pathway is unaffected and an error log line is emitted. Verify that the telemetry handler remains attached after the failure.
- **Defensive metadata handling**: emit a telemetry event with missing optional metadata fields (e.g., no command key for a read_file type), assert the audit row is created with null values for the missing fields and no crash occurs.
- **Debug endpoint auth**: GET /commands without auth returns 401, with valid auth returns 200 and a JSON object with a "commands" key containing an array.
- **Debug endpoint ordering**: returned rows are in descending started_at order, and limit param is respected.
- **Debug endpoint limit cap**: GET /commands?limit=9999 returns at most 100 rows.
- **Debug endpoint invalid limit**: GET /commands?limit=abc returns rows using the default limit of 20.
- **Debug endpoint machine filter**: GET /commands?machine=X returns only rows matching that machine name, and omitting the param returns all rows.
- **Debug endpoint combined filters**: GET /commands?machine=X&limit=5 returns at most 5 rows, all matching the specified machine.
- **Debug endpoint JSON shape**: verify that null fields appear as null in the JSON response and that timestamps are ISO 8601 strings.

**Note on latency testing:** The "round-trip latency under 10ms" criterion is validated manually, not as an automated test. Automated latency assertions are inherently flaky across different CI environments and hardware. The manual validation step (described below) covers this.

### Validation

- Test suite passes
- Manual: connect an agent, run a few shell commands via MCP, hit /commands with the auth token, verify rows appear with correct fields. Measure round-trip latency for a no-op shell command and confirm it remains under 10ms.
- Manual: verify auto-migration works by deleting the dev database and restarting the application
- Manual: verify that stopping the Repo process mid-operation does not affect command dispatch
- Manual: verify that the application starts and serves commands normally when the database file does not exist (auto-create and auto-migrate)

## Notes

- Storing the `content` field for `write_file` would blow up the DB on anything non-trivial. We record `path` and `type`; if you need to reconstruct the write, look at the client-side chat history.
- The debug endpoint is intentionally minimal. Anything richer (filters, pagination, search) should wait until there's a concrete user complaint.
- If the audit log ever becomes a hotspot, the Task.Supervisor fan-out can be replaced with a batching writer GenServer. Not needed at expected volumes.
- The exqlite NIF requires a C compiler at build time. The SPEC-8 Dockerfile must include build-essential in the build stage. The runtime stage does not need a C compiler since the NIF is compiled into the release.
- Orphaned "running" rows will accumulate if the server crashes between a start and stop event. This is acceptable — these rows are still useful for debugging ("this command was in flight when the server died"). Do not add a cleanup mechanism now; if it becomes noisy, a startup sweep that marks stale "running" rows as "unknown" can be added later.
- The `output` and `error` columns are unbounded text. For shell commands that produce very large output, this could result in large rows. This is acceptable for an audit log at expected volumes. If it becomes a problem, truncation can be added to the audit writer later. Do not add truncation now — premature limits are harder to debug than large rows.
- Disk space exhaustion on the persistent volume will cause audit writes to fail silently (errors logged, dispatches unaffected). There is no proactive disk space monitoring in this spec. If this becomes a production concern, it should be addressed at the infrastructure level (volume monitoring in Fly.io) rather than in the application. Log retention/cleanup is explicitly out of scope for now, but is the natural mitigation if disk pressure becomes real.

## Observations

- [decision] Ecto plus SQLite with WAL — boring, proven, zero ops overhead, single-file backup story
- [decision] Audit writer subscribes to telemetry events emitted by the dispatcher in SPEC-4 — zero coupling in the hot path
- [decision] Async writes via Task.Supervisor — audit latency is invisible to the dispatcher
- [decision] Upsert on stop events to handle start/stop race — correctness without serialization
- [decision] content field deliberately not stored — audit should not become a blob store
- [decision] /commands debug endpoint reuses AUTH_TOKEN — not worth a separate secret for an operator-only endpoint
- [decision] Dev uses priv/data/audit.db, prod uses DATABASE_PATH env var — environment-appropriate defaults
- [decision] Pool size of 1 — SQLite single-writer constraint makes larger pools counterproductive
- [decision] Response envelope with commands key — leaves room for metadata without breaking changes
- [decision] Auto-migrate on startup — appropriate for single-file SQLite, eliminates manual deploy step
- [decision] Graceful degradation — audit failure on startup does not prevent the application from serving commands
- [invariant] Audit writer failures must never propagate to the dispatcher — enforced by rescue plus async task
- [invariant] Telemetry handlers must never be detached due to audit failures — enforced by rescue inside handler function before async dispatch
- [invariant] Start/stop write ordering must not affect final row correctness — enforced by upsert strategy
- [invariant] Upsert on stop must produce a complete row with all start-event fields — requires stop metadata to carry full context
- [pattern] Telemetry events from SPEC-4 are the integration surface — not a direct call from the dispatcher
- [pattern] Tests emit telemetry events directly rather than requiring a full agent/dispatcher stack
- [risk] Orphaned "running" rows on server crash — acceptable, useful for debugging, no cleanup needed now
- [risk] Stop-event upsert requires all start-event fields in stop metadata — if SPEC-4 does not include them, the upsert row will have nulls for start-only fields; coordinate with SPEC-4 implementer
- [risk] Unbounded output/error column size — acceptable at expected volumes, add truncation only if needed
- [risk] Disk space exhaustion causes silent audit write failures — mitigate at infrastructure level, not in application
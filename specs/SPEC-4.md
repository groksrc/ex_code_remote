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

For the person using this system through an MCP client, these problems surface as sluggish command execution, commands that hang indefinitely when an agent disconnects, and intermittent failures that are difficult to diagnose. Every tool invocation — running a shell command, reading a file, listing a directory — passes through this dispatch path, so the reliability and responsiveness of this single component defines the felt quality of the entire product.

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
- Command-type-specific field validation — the Dispatcher passes the command map through as-is; validation of which fields are required for which command type belongs in the MCP tool handlers (SPEC-5)

## Dependencies

This spec builds on and requires the following from prior specs:

- **SPEC-2 (Wire Protocol):** Defines the shape of the `execute` and `result` JSON frames exchanged over the WebSocket. This spec consumes those frame definitions but does not alter them. The implementer must refer to SPEC-2 for the exact field names and types used when building outbound `execute` frames and parsing inbound `result` frames. SPEC-2 should also provide shared encoding and decoding functions (a codec) that the Connection reuses when building `execute` frames and parsing `result` frames. The Connection should call into that codec rather than reimplementing the wire format conversion.
- **SPEC-3 (Agent Connection):** Provides the `ExCodeRemote.Agent.Connection` GenServer, the `ExCodeRemote.Agent.Registry` for machine-name-to-PID lookups, and the Socket process that handles raw WebSocket I/O. The Socket process is a separate process owned by the Connection that manages the raw WebSocket transport — the Connection sends outbound frames to the Socket for transmission and receives inbound frames forwarded by the Socket. SPEC-3 introduces a stub `:pending` map in Connection state — this spec makes that map load-bearing. The implementer must also know which Registry lookup function to call (the function that takes a machine name string and returns either a Connection PID or an indication that no agent is connected).

**Downstream dependents:**

- **SPEC-5 (MCP Tools):** First caller of `Dispatcher.run/2`. The public API defined here must be stable before SPEC-5 implementation begins.
- **SPEC-6 (Audit) and SPEC-7:** Subscribe to the telemetry events emitted by this spec. The telemetry event names and metadata shapes defined here become a contract for those specs.

## How (High Level)

### Public API

The `ExCodeRemote.Commands.Dispatcher` module exposes a single function: `run(machine, command)`. The command map contains a `type` (one of `:shell`, `:read_file`, `:write_file`, `:list_dir`), along with optional fields like `command`, `path`, `content`, `working_dir`, and `timeout`.

Which optional fields are relevant depends on the command type: `:shell` uses `command`, `working_dir`, and `timeout`; `:read_file` and `:list_dir` use `path`; `:write_file` uses `path` and `content`. The Dispatcher does not validate these combinations — it passes the command through to the agent. Validation of required fields per command type belongs in the MCP tool handlers (SPEC-5).

If `timeout` is not supplied, the Dispatcher uses a default of 60 seconds. The default timeout value should be defined as a module attribute so it is visible in one place.

The return value is either `{:ok, result}` or `{:error, reason}`.

On success, the result map contains the following fields with these types:

- `status` — a string (for example, `"completed"` or `"error"`)
- `output` — a string containing the command's standard output, or an empty string if none
- `error` — a string containing the command's standard error or error message, or an empty string if none
- `exit_code` — an integer representing the process exit code (for shell commands), or `nil` for command types that do not produce an exit code

These fields and their types mirror the `result` frame defined in SPEC-2. The Dispatcher does not transform or rename them — it passes the parsed result through to the caller.

On failure, `reason` is one of `:not_connected`, `:timeout`, or `:agent_disconnected`. This error taxonomy is deliberately small and stable — SPEC-5's MCP tool handlers can map each reason to a clear, user-facing error message without needing to understand dispatch internals. Callers should never receive raw BEAM exit signals from a failed dispatch.

The `machine` argument is a string (the machine name the agent registered with). The `command` argument is a map with atom keys.

### Dispatcher Flow

The dispatcher is a pure module (no process of its own). It:

1. Emits the telemetry `:start` event with system time and metadata containing the machine name and command type. The command ID in the metadata is `nil` at this point, since it has not been generated yet. If the Registry lookup in the next step fails, the command ID will remain `nil` in both the `:start` and `:stop` events.
2. Resolves the machine name via Agent.Registry to find the Connection PID, or returns `{:error, :not_connected}`.
3. Generates a URL-safe random command ID.
4. Resolves the effective timeout: reads the `timeout` value from the command map, falling back to the default (60 seconds) if not present. All subsequent timeout calculations use this resolved value.
5. Calls `Agent.Connection.dispatch(pid, command_id, command)` as a GenServer.call with a timeout of the resolved timeout plus five seconds of slack (converted to milliseconds). The five-second slack accounts for round-trip overhead between the Dispatcher and the Connection.
6. If the GenServer.call exits with a timeout, catches the exit and returns `{:error, :timeout}`. The caller must not crash on a timed-out dispatch. The catch must also handle the case where the Connection process has died between the Registry lookup and the GenServer.call — this manifests as an exit with reason `:noproc`, and should be returned as `{:error, :not_connected}`. If the GenServer.call returns normally, the return value is either a success tuple or an error tuple from the Connection — the Dispatcher passes these through without transformation.
7. Emits the telemetry `:stop` event before returning, regardless of success or failure. This means the telemetry brackets the entire dispatch attempt, including the time spent waiting for the agent response.
8. Returns the result or error.

### Connection GenServer Changes

The Connection's `:pending` map (introduced as a stub in SPEC-3) becomes load-bearing:

**On dispatch call:** The Connection receives the dispatch as a `handle_call`. It builds an `execute` frame from the command using the wire protocol codec defined in SPEC-2 (converting the command map's atom keys into the string-keyed JSON format specified there), sends it to the Socket process for transmission, stores the caller's `from` reference keyed by `command_id`, and returns `:noreply` — the caller blocks. This is the standard OTP deferred-reply pattern. The Connection also schedules a server-side timeout guard message at this point (see "Timeout and Stale Pending Entries" below).

**On result frame:** When the Socket forwards a `result` frame, the Connection looks up the command ID in the pending map. If found, it pops the entry (both the `from` reference and the associated timeout timer reference), cancels the timer, builds a result map from the frame's fields using the SPEC-2 codec, and calls `GenServer.reply/2` to unblock the waiting caller. If the ID is unknown (late arrival, duplicate), it is silently ignored.

**On send failure:** If the Socket process is not alive or the send fails, the Connection must reply immediately with `{:error, :not_connected}` rather than stashing the `from` — otherwise the caller blocks with no possibility of a response. The Connection should check that the Socket process is alive before attempting to send. If the send itself fails (for example, the Socket process dies between the alive check and the send), the Connection must still reply with an error and must not leave a dangling entry in the pending map. Note that this error is returned as a normal GenServer reply (not an exit), so the Dispatcher receives it as the return value of `GenServer.call` and passes it through.

### Timeout and Stale Pending Entries

There is a race between the caller's GenServer.call timeout and a late-arriving result. When a caller times out, OTP delivers an exit to the caller, but the `from` and its pending map entry remain in the Connection's state. A result arriving after the timeout will find the entry, call `GenServer.reply/2` on the already-dead caller (which is a silent no-op), and `Map.pop` will remove the entry. This means the pending map is self-cleaning in the normal case.

However, if the agent never responds at all (no result frame ever arrives), the pending entry leaks permanently. To guard against this, the Connection should schedule a delayed message to itself for each pending command (using `Process.send_after` with the command's timeout plus slack). The pending map value should store both the caller's `from` reference and the timer reference returned by `Process.send_after`, so that the timer can be cancelled when a result arrives normally. When the timeout message arrives, if the command ID is still in the pending map, the Connection pops it, cancels (or ignores) the timer reference, and replies with `{:error, :timeout}`. This ensures entries cannot accumulate indefinitely even if the agent silently drops commands.

The slack on the server-side timeout guard should be slightly longer than the slack on the GenServer.call timeout (for example, 10 seconds versus 5 seconds) so that in normal operation, the caller-side timeout fires first and the server-side guard only fires for true no-response cases.

### Cancellation on Disconnect

When the Connection GenServer terminates (for any reason — clean shutdown, agent disconnect, or unexpected crash), its `terminate/2` callback iterates over all entries in the pending map and replies with `{:error, :agent_disconnected}` to each. It also cancels any outstanding timer references to avoid sending timeout messages to a dead process. This ensures no caller can hang past a dropped connection. The `:agent_disconnected` error is used for all termination reasons because, from the caller's perspective, the effect is the same: the agent is no longer reachable through this Connection.

### Command ID Generation

Command IDs are generated server-side using 12 bytes of cryptographic randomness, base64url-encoded without padding, producing a 16-character string. The agent never generates IDs — it just echoes the string from `execute` into `result`. The generation function should live in the Dispatcher module (or a small helper it calls) so tests can verify the format independently.

### Telemetry Hooks

The dispatcher emits two telemetry events that SPEC-6 and SPEC-7 will subscribe to:

- `[:ex_code_remote, :dispatcher, :command, :start]` — with system time and metadata containing machine name, command ID, and command type.
- `[:ex_code_remote, :dispatcher, :command, :stop]` — with duration and metadata containing machine name, command ID, command type, and final status (including error cases like `:timeout` and `:agent_disconnected`).

The `:stop` event must be emitted for every `:start` event, regardless of outcome. This means the Dispatcher is responsible for emitting `:stop` even when the dispatch fails with a timeout or disconnect — not just on successful results. This invariant is important for downstream consumers that pair start/stop events.

The metadata for both events should include the same set of identifying fields (machine name, command ID, command type) so consumers can correlate them. The `:stop` metadata additionally includes a `status` field that is either `:ok`, `:timeout`, `:agent_disconnected`, or `:not_connected`.

The `:not_connected` status covers two distinct failure paths: the Registry lookup failing (no Connection PID found, command ID is `nil` in metadata) and the Connection's Socket being dead at send time (Connection replies with an error, command ID is present in metadata). Both produce the same status in the telemetry event, but the presence or absence of a command ID distinguishes them for consumers that need to differentiate.

These are hooks, not business logic. The dispatcher works without any subscribers.

## How to Evaluate

### Success Criteria

**Product-level outcomes:**

- [ ] Commands dispatched through the new path complete without user-visible delay attributable to the dispatch layer itself — the latency budget is spent on agent execution, not on coordination overhead
- [ ] When an agent disconnects mid-command, every waiting caller receives a definitive error within seconds, not after a timeout — the user is never left wondering whether their command is still running
- [ ] The dispatch path has no failure mode that causes a caller to hang indefinitely — every dispatch resolves to either a result or an explicit error

**Technical verification:**

- [ ] `Dispatcher.run/2` returns `{:error, :not_connected}` for unknown machines
- [ ] `Dispatcher.run/2` returns `{:error, :not_connected}` when the Connection is alive but its Socket has died (send failure path)
- [ ] `Dispatcher.run/2` against a connected agent sends an `execute` frame and blocks until the matching `result` arrives
- [ ] The result map returned on success contains `status`, `output`, `error`, and `exit_code` with the correct types described in the Public API section
- [ ] Round-trip latency for a no-op command is under 10ms in tests (compared to 500ms minimum in the Python version)
- [ ] When `timeout` is not supplied in the command map, the Dispatcher uses the default of 60 seconds and the GenServer.call deadline reflects the default plus slack
- [ ] Pending callers are unblocked with `{:error, :agent_disconnected}` when the Connection terminates
- [ ] Unknown/duplicate result IDs are silently ignored without crashing the Connection or corrupting pending state
- [ ] Caller timeout is respected and exceeds `command.timeout` by at least 5s of slack
- [ ] When the agent never responds, the pending entry is cleaned up by the server-side timeout guard rather than leaking indefinitely
- [ ] Telemetry `:start` and `:stop` events are emitted for every dispatch, including failures
- [ ] The `:stop` event is emitted even when the dispatch ends in `:timeout` or `:agent_disconnected`
- [ ] Telemetry `:start` and `:stop` events are both emitted when the machine is not found in the Registry, with `nil` as the command ID
- [ ] A `:noproc` exit from GenServer.call (Connection died between lookup and call) is caught and returned as `{:error, :not_connected}` rather than crashing the caller
- [ ] The server-side timeout guard cancels its timer when a result arrives normally, rather than leaving timers running unnecessarily
- [ ] The pending map stores timer references alongside `from` references, and both are cleaned up on result, timeout, and disconnect

### FakeAgent Test Helper

The FakeAgent is a reusable test support module that lives in a shared test support directory (such as `test/support/`). It connects to the server via a WebSocket client library, performs the agent handshake defined in SPEC-3 (registering under a given machine name), and handles incoming `execute` frames by invoking a caller-provided response function.

The response function receives the full `execute` frame as its argument, so it can inspect the command ID, command type, and other fields to decide how to respond. This is important for concurrent dispatch tests where the FakeAgent must correlate responses to specific commands.

The FakeAgent must support at least these behaviors, controlled by the response function passed at creation time:

- **Immediate response:** Receives an `execute` frame and immediately sends back a `result` frame with `status: "completed"` and caller-specified output.
- **Delayed response:** Waits a configurable duration before sending the result. Used to test that the system behaves correctly when responses arrive just before or just after timeouts.
- **No response:** Receives the `execute` frame but never sends a result. Used to test the server-side stale-entry cleanup.
- **Unrecognized ID response:** Sends a `result` frame with a command ID that does not match any pending command. Used to test the unknown-ID path.
- **Disconnect before responding:** Closes the WebSocket connection after receiving the `execute` frame but before sending a result. Used to test the disconnect cancellation path.

The FakeAgent should provide a way for tests to assert on what frames it received (for example, the exact `execute` frame payload), so tests can verify the outbound wire format without inspecting internal state.

### Tests

Tests should be included with the implementation changes.

- **Dispatcher against unknown machine** returns `{:error, :not_connected}`.
- **Dispatcher against a connected FakeAgent** that echoes a `completed` result returns `{:ok, result}` with expected fields. The test should verify that the result map contains `status`, `output`, `error`, and `exit_code` with the correct values and types from the FakeAgent's response.
- **Round-trip latency** is under 10ms (using timer measurement).
- **Default timeout applied** — dispatching a command with no `timeout` field in the command map should use the default timeout. This can be verified indirectly by confirming the dispatch does not fail with an arithmetic or nil-reference error when timeout is omitted, and more directly by observing the GenServer.call deadline if the test framework allows it.
- **Telemetry events** `:start` and `:stop` are captured in order with matching command IDs. Use a telemetry handler attached in test setup that captures events to a test process's mailbox.
- **Telemetry on failure** — `:stop` is emitted with error status when the dispatch times out or the connection drops.
- **Telemetry on not_connected** — `:start` and `:stop` are both emitted even when the machine is not found in the Registry. The command ID in the metadata should be `nil`.
- **Connection terminate with pending callers** — all callers receive `{:error, :agent_disconnected}`. This test should have multiple concurrent callers waiting on the same Connection, then kill the Connection and assert that every caller receives the disconnect error.
- **Unknown result ID** — a result frame with an unrecognized command ID does not crash the Connection or affect pending state. After sending the unknown result, dispatch a real command and verify it succeeds normally.
- **Caller timeout** — when the FakeAgent does not respond and the command timeout elapses, the caller receives `{:error, :timeout}` and the pending map entry is cleaned up. Use a short timeout (such as 100ms) to keep the test fast.
- **Server-side timeout guard** — when the FakeAgent never responds and enough time passes, the server-side guard fires and cleans up the pending entry. This is distinct from the caller timeout test: here the test should verify the Connection's internal state is clean after the guard fires, not just that the caller got an error.
- **Late result after timeout** — when the FakeAgent responds after the caller has timed out, the Connection handles the result gracefully (no crash, no error log) and the pending map does not leak.
- **Concurrent dispatches** — multiple callers dispatching to the same agent concurrently each receive their own correlated result without cross-talk. At least three concurrent dispatches should be tested to exercise the map-based correlation under contention. The FakeAgent's response function should use the command ID from each `execute` frame to produce distinct results, so the test can verify each caller received its own response.
- **Connection dies between Registry lookup and GenServer.call** — the Dispatcher catches the `:noproc` exit and returns `{:error, :not_connected}`.
- **Socket dead while Connection alive** — when the Connection's Socket process has died but the Connection itself is still running, dispatching a command returns `{:error, :not_connected}` from the Connection's send-failure path (not from a GenServer exit). This is distinct from the `:noproc` test and exercises the Connection's alive-check logic.
- **FakeAgent frame inspection** — at least one test should verify that the `execute` frame sent to the FakeAgent matches the expected wire format from SPEC-2 (correct field names, correct command ID, correct command type).

### Validation

- `mix test` passes
- Manual: with the Python agent connected and running on a reachable machine, use an IEx session to call `Dispatcher.run/2` with a shell command and observe the result immediately

## Task Decomposition

This section describes the discrete implementation tasks within this spec and their dependencies on each other. Tasks that do not depend on each other can be worked in parallel.

**Task 1: Command ID generation.** Implement the function that generates a 16-character URL-safe random string from 12 bytes of cryptographic randomness. This is a pure function with no dependencies on other tasks and can be built and tested in isolation.

**Task 2: FakeAgent test helper.** Build the FakeAgent module in the shared test support directory. This requires the WebSocket endpoint and agent handshake from SPEC-3 to be working, but does not depend on any other task in this spec. The FakeAgent is needed by all subsequent test tasks, so it should be built early.

**Task 3: Connection GenServer changes.** Modify the Connection GenServer to handle the dispatch call (stashing `from` and timer reference in the pending map, building and sending the `execute` frame via the SPEC-2 codec), handle inbound `result` frames (looking up and popping the pending entry, cancelling the timer, replying to the caller), handle the server-side timeout guard message, handle send failures (replying immediately with an error when the Socket is dead), and handle disconnect cleanup in `terminate/2`. This task depends on the pending map stub from SPEC-3 and the wire format from SPEC-2. It is the largest single task in this spec.

**Task 4: Dispatcher module.** Implement `Dispatcher.run/2` with telemetry emission, Registry lookup, command ID generation, default timeout resolution, GenServer.call with timeout, exit catching, and error passthrough. This depends on Task 1 (command ID generation) and Task 3 (Connection GenServer changes). It is a thin orchestration layer and should be straightforward once the Connection changes are in place.

**Task 5: Tests.** Write the full test suite described above. This depends on Task 2 (FakeAgent), Task 3 (Connection changes), and Task 4 (Dispatcher module). Some tests (such as the command ID format test) can be written alongside their respective tasks.

## Notes

- The biggest risk in this spec is a subtle leak in the pending map: if a result never arrives (agent drops the command), the server-side timeout guard described in the "Timeout and Stale Pending Entries" section is the mitigation. Without it, a misbehaving agent could cause unbounded memory growth in the Connection process.
- Telemetry is a standalone library included by most Elixir projects. If it is not already in the project's dependency list (either directly or transitively), it must be added before this spec can be implemented. The implementer should verify this as a first step.
- SPEC-5 (MCP tools) is the first caller of `Dispatcher.run/2`, so the public API must be stable before that spec is written.
- The FakeAgent test helper should live in a shared test support directory so SPEC-5 and later specs can import it without duplication.
- The Dispatcher must catch exits from `GenServer.call` rather than letting them propagate. A timed-out or crashed Connection should not crash the calling process (which will be an MCP tool handler in SPEC-5).
- The pending map value is not just the `from` reference — it is a tuple (or small map) containing both the `from` reference and the timer reference. This is important for the implementer to get right; storing only `from` will lead to timer leaks.
- When building the `execute` frame in the Connection, the implementer should use the wire protocol codec from SPEC-2 (if one exists) rather than reimplementing the atom-to-string key conversion. If SPEC-2 does not provide a shared codec module, one should be extracted during this spec's implementation so the encoding logic lives in one place.
- The Dispatcher does not validate that the command `type` is one of the four known types. An unrecognized type will be sent to the agent as-is. This is deliberate — the Dispatcher is a transport layer, not a validation layer — but it means a typo in the command type will only fail at the agent, not at dispatch time.
- This spec is the critical path for the entire port's value proposition. If the dispatch layer is unreliable or slow, no amount of polish in the MCP tools (SPEC-5), audit system (SPEC-6), or other downstream specs will recover the user experience. The bar for correctness and test coverage here should be treated accordingly.

## Observations

- [decision] In-memory `command_id => from` map on the owning Connection GenServer — the canonical BEAM pattern for request/response over a long-lived socket
- [decision] Dispatcher is a plain module, not a process — no bottleneck, no mailbox contention, and the Connection is the only stateful actor
- [decision] Server generates command IDs, agent echoes them — agent remains dumb, wire format matches existing Python agent
- [decision] Disconnect cancels pending callers via `terminate/2` — no caller can hang past a dropped connection
- [decision] Telemetry events are emitted as hooks, consumers decided later — dispatcher has no runtime dependency on audit or metrics
- [decision] Server-side timeout guard cleans stale pending entries — prevents unbounded memory growth from unresponsive agents
- [decision] Pending map values store both `from` and timer references — ensures clean cancellation on all paths
- [decision] Error taxonomy is small, stable, and caller-friendly — three error reasons give downstream MCP handlers everything they need to produce clear user-facing messages without coupling to dispatch internals
- [anti-pattern] Polling a database for state the WebSocket already delivered — this is the Python version's core bug, specifically not reproduced
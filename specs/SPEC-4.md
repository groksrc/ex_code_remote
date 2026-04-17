---
title: 'SPEC-4: Command Dispatch and Result Correlation'
type: spec
permalink: specs/spec-4-command-dispatch-and-result-correlation
tags:
- dispatch
- correlation
- genserver
- core
status: implemented
---

# SPEC-4: Command Dispatch and Result Correlation

## Why

This is the core architectural fix that motivates the entire port. The Python server's `execute_command` function inserts a row into SQLite, sends the command over the WebSocket, then **polls the database every 500ms** waiting for the agent's result to land as a row update. That pattern is the direct cause of several stability problems:

1. Two sources of truth (WebSocket and SQLite) for the same command state.
2. 500ms of wasted latency per command, every time.
3. No clean cancellation path — a polling loop can't be notified of a disconnect.
4. If the WebSocket delivers the result but the database write fails, the caller hangs until timeout.

For the person using this system through an MCP client, these problems surface as sluggish command execution, commands that hang indefinitely when an agent disconnects, and intermittent failures that are difficult to diagnose. Every tool invocation — running a shell command, reading a file, listing a directory — passes through this dispatch path, so the reliability and responsiveness of this single component defines the felt quality of the entire product.

The cumulative impact is significant. A typical interactive coding session involves dozens to hundreds of tool invocations. At 500ms of overhead per command, a session accumulates minutes of dead time that the user experiences as the tool being "slow" — not catastrophically broken, but persistently frustrating in a way that erodes trust and makes the tool feel unreliable. Eliminating that overhead is the single highest-leverage improvement this port delivers.

BEAM's answer is straightforward: the GenServer that owns the socket also owns a map of `command_id => from`. When a caller invokes `GenServer.call`, we stash the `from` in the map and don't reply yet. When the agent's `result` frame arrives, we look up the `from` by `command_id` and reply directly. The caller unblocks the instant the bytes arrive. No polling. No database in the request path. No cancellation ambiguity.

The target experience is that command dispatch feels instantaneous — the user's perception of latency should be dominated entirely by the time the remote agent spends executing the command, not by anything the server does to coordinate the request and response.

## What

**In scope:**

- `ExCodeRemote.Commands.Dispatcher` — the public entry point used by MCP tool handlers
- `ExCodeRemote.Agent.Connection.dispatch/3` — synchronous send-and-wait primitive on the Connection GenServer
- Pending-command state on the Connection GenServer (a map of command ID to the caller's `from` reference and timer reference)
- Command ID generation (URL-safe random, server-side)
- Timeout handling — both the caller timeout and the command's own `timeout` field
- Server-side timeout guard — a per-command delayed message that cleans up pending entries when the agent never responds
- Cancellation on agent disconnect — all pending callers receive `{:error, :agent_disconnected}` when the Connection terminates
- A `FakeAgent` test helper for use here and in future specs

**Out of scope:**

- MCP tool handlers calling `Dispatcher.run/2` (SPEC-5)
- Audit writes (SPEC-6 — but the dispatcher emits telemetry hooks that the audit module will subscribe to later)
- Retries — the dispatcher does not retry; failed dispatches surface as errors to the caller
- Command-type-specific field validation — the Dispatcher passes the command map through as-is; validation of which fields are required for which command type belongs in the MCP tool handlers (SPEC-5)
- Backpressure or admission control on the number of concurrent pending commands per Connection — see the Known Limitations section below for the conditions under which this would need to be revisited

## Dependencies

This spec builds on and requires the following from prior specs:

- **SPEC-2 (Wire Protocol):** Defines the shape of the `execute` and `result` JSON frames exchanged over the WebSocket. This spec consumes those frame definitions but does not alter them. The implementer must refer to SPEC-2 for the exact field names and types used when building outbound `execute` frames and parsing inbound `result` frames. SPEC-2 should also provide shared encoding and decoding functions (a codec) that the Connection reuses when building `execute` frames and parsing `result` frames. The Connection should call into that codec rather than reimplementing the wire format conversion. If SPEC-2 does not provide a codec module, the implementer must extract one during this spec's implementation so the encoding logic lives in one place.
- **SPEC-3 (Agent Connection):** Provides the `ExCodeRemote.Agent.Connection` GenServer, the `ExCodeRemote.Agent.Registry` for machine-name-to-PID lookups, and the Socket process that handles raw WebSocket I/O. The Socket process is a separate process owned by the Connection that manages the raw WebSocket transport — the Connection sends outbound frames to the Socket for transmission and receives inbound frames forwarded by the Socket. The Connection must use whatever send mechanism SPEC-3 defined for communicating with the Socket process (whether that is a plain `send/2`, a `GenServer.cast`, or a function call on a Socket API module). SPEC-3 introduces a stub `:pending` map in Connection state — this spec makes that map load-bearing. The implementer must also know which Registry lookup function to call (the function that takes a machine name string and returns either a Connection PID or an indication that no agent is connected). The implementer should read the Connection module and identify the exact function name, the send mechanism for the Socket, and how the Socket forwards inbound frames to the Connection before beginning work. **SPEC-3 implementation must be complete before this spec's Connection modifications begin.** This spec adds new `handle_call`, `handle_info`, and `terminate/2` clauses to the Connection GenServer; attempting to do so against an in-progress SPEC-3 implementation will create merge conflicts and ambiguous state assumptions.
- **Telemetry library:** The Dispatcher emits telemetry events. The `:telemetry` library is already present in the project's dependency list (confirmed in the `deps/` directory). The implementer should verify it is listed in the `deps` function of `mix.exs` as a direct dependency and not merely transitive — if it is only transitive, add it explicitly so it is not silently removed by a future dependency change.

**Downstream dependents:**

- **SPEC-5 (MCP Tools):** First caller of `Dispatcher.run/2`. The public API defined here must be stable before SPEC-5 implementation begins.
- **SPEC-6 (Audit) and SPEC-7 (Observability):** Subscribe to the telemetry events emitted by this spec. The telemetry event names and metadata shapes defined here become a contract for those specs.

## How (High Level)

### Public API

The `ExCodeRemote.Commands.Dispatcher` module exposes a single function: `run(machine, command)`. The command map contains a `type` (one of `:shell`, `:read_file`, `:write_file`, `:list_dir`), along with optional fields like `command`, `path`, `content`, `working_dir`, and `timeout`.

Which optional fields are relevant depends on the command type: `:shell` uses `command`, `working_dir`, and `timeout`; `:read_file` and `:list_dir` use `path`; `:write_file` uses `path` and `content`. The Dispatcher does not validate these combinations — it passes the command through to the agent. Validation of required fields per command type belongs in the MCP tool handlers (SPEC-5).

If `timeout` is not supplied, the Dispatcher uses a default of 60 seconds. The default timeout value should be defined as a module attribute so it is visible in one place. The `timeout` field in the command map is always in seconds (an integer). All internal timeout arithmetic — the GenServer.call deadline, the server-side timeout guard — starts from this value and converts to milliseconds as needed.

The return value is either `{:ok, result}` or `{:error, reason}`.

On success, the result map contains the following fields with these types:

- `status` — a string (for example, `"completed"` or `"error"`)
- `output` — a string containing the command's standard output, or an empty string if none
- `error` — a string containing the command's standard error or error message, or an empty string if none
- `exit_code` — an integer representing the process exit code (for shell commands), or `nil` for command types that do not produce an exit code

These fields and their types mirror the `result` frame defined in SPEC-2. The Dispatcher does not transform or rename them — it passes the parsed result through to the caller. If the agent's result frame omits a field entirely (as opposed to sending an explicit null), the SPEC-2 codec is responsible for normalizing the omission to the default value for that field's type (empty string for string fields, `nil` for `exit_code`). The Dispatcher relies on this normalization and does not apply its own defaults.

On failure, `reason` is one of `:not_connected`, `:timeout`, or `:agent_disconnected`. This error taxonomy is deliberately small and stable — SPEC-5's MCP tool handlers can map each reason to a clear, user-facing error message without needing to understand dispatch internals. Callers should never receive raw BEAM exit signals from a failed dispatch.

The `machine` argument is a string (the machine name the agent registered with). The `command` argument is a map with atom keys.

The Dispatcher makes no ordering guarantees about command execution. Even if two commands are dispatched sequentially to the same agent, the agent may process and respond to them in any order. Callers must not depend on dispatch order matching result order.

### Dispatcher Flow

The dispatcher is a pure module (no process of its own). It:

1. Generates a URL-safe random command ID. This happens first so that the command ID is available for all subsequent steps, including telemetry.
2. Emits the telemetry `:start` event with system time and metadata containing the machine name, command ID, and command type. The command type is read from the `:type` key of the command map. If the command map does not contain a `:type` key, the metadata value for `command_type` should be `nil` — the Dispatcher does not reject the command for this reason, since type validation belongs in SPEC-5. Because the command ID was generated in the previous step, it is always present in both `:start` and `:stop` events, making correlation trivial for downstream consumers.
3. Resolves the machine name via Agent.Registry to find the Connection PID, or returns `{:error, :not_connected}`. The `:stop` telemetry event must be emitted before returning, even on this early-exit path.
4. Resolves the effective timeout: reads the `timeout` value from the command map, falling back to the default (60 seconds) if not present. All subsequent timeout calculations use this resolved value.
5. Calls `Agent.Connection.dispatch(pid, command_id, command)` as a GenServer.call with a timeout of the resolved timeout plus five seconds of slack (converted to milliseconds). The five-second slack accounts for round-trip overhead between the Dispatcher and the Connection. The timeout passed to the Connection in the command map remains the unmodified resolved timeout in seconds — the slack is only applied to the GenServer.call deadline.
6. If the GenServer.call exits with a timeout, catches the exit and returns `{:error, :timeout}`. The caller must not crash on a timed-out dispatch. The catch must also handle the case where the Connection process has died between the Registry lookup and the GenServer.call — this manifests as an exit with reason `:noproc`, and should be returned as `{:error, :not_connected}`. If the GenServer.call returns normally, the return value is either a success tuple or an error tuple from the Connection — the Dispatcher passes these through without transformation.
7. Emits the telemetry `:stop` event before returning, regardless of success or failure. This means the telemetry brackets the entire dispatch attempt, including the time spent waiting for the agent response.
8. Returns the result or error.

The Dispatcher uses manual telemetry emission (individual `:start` and `:stop` calls) rather than the `Telemetry.span/3` helper. This is deliberate: the Dispatcher needs the `:start` event emitted before the Registry lookup, and needs to catch exits from the GenServer.call before emitting `:stop`. The span helper's callback-based API does not accommodate this control flow cleanly.

The exit-catching logic in step 6 must be implemented using a try/catch around the GenServer.call. The catch clause should match on `:exit` with a tuple of `{:timeout, _}` for timeout and `{:noproc, _}` for a dead process. Any other exit reason from the GenServer.call should also be caught and returned as `{:error, :not_connected}` rather than propagating, since from the caller's perspective any unexpected Connection failure is equivalent to the agent being unreachable.

### Connection GenServer Changes

The Connection's `:pending` map (introduced as a stub in SPEC-3) becomes load-bearing:

**On dispatch call:** The Connection receives the dispatch as a `handle_call`. It builds an `execute` frame from the command using the wire protocol codec defined in SPEC-2 (converting the command map's atom keys into the string-keyed JSON format specified there), sends it to the Socket process for transmission, stores the caller's `from` reference keyed by `command_id`, and returns `:noreply` — the caller blocks. This is the standard OTP deferred-reply pattern. The `from` value is opaque — it must only be stored and later passed to `GenServer.reply/2`, never inspected or destructured. The Connection also schedules a server-side timeout guard message at this point (see "Timeout and Stale Pending Entries" below).

The `handle_call` clause must match on a specific message shape (for example, a tuple containing the dispatch atom, the command ID, and the command map) so it does not conflict with any other `handle_call` clauses the Connection may already have from SPEC-3.

The pending map key is always a string (the command ID as generated by the Dispatcher). The result frame's command ID will also arrive as a string from the JSON wire format. The implementer must ensure the key types match between insertion and lookup — no atom-to-string conversion should be needed since both sides use strings.

**On result frame:** When the Socket forwards a `result` frame, the Connection looks up the command ID in the pending map. If found, it pops the entry (both the `from` reference and the associated timeout timer reference), cancels the timer, builds a result map from the frame's fields using the SPEC-2 codec, and calls `GenServer.reply/2` to unblock the waiting caller. If the ID is unknown (late arrival, duplicate), it is silently ignored. The Connection must not log at warning or error level for unknown IDs, since late arrivals after timeout are expected in normal operation — debug-level logging is acceptable for observability.

**Defensive result-frame parsing:** The result-frame handling in the Connection must be defensive against malformed frames from the agent. If a result frame arrives with valid JSON but missing or incorrectly-typed fields (for example, no `status` field, or `output` is a number instead of a string), the Connection must not crash. A crash in `handle_info` would terminate the Connection process, which in turn would send `{:error, :agent_disconnected}` to every pending caller — not just the caller whose command produced the malformed response. The Connection should treat a malformed result frame the same way it treats an unknown command ID: discard it silently (or log at debug level) and leave the pending entry in place for the server-side timeout guard to clean up. The SPEC-2 codec's decoding function should return an error tuple for unparseable frames rather than raising, and the Connection should handle that error tuple.

**On send failure:** If the Socket process is not alive or the send fails, the Connection must reply immediately with `{:error, :not_connected}` rather than stashing the `from` — otherwise the caller blocks with no possibility of a response. The Connection should check that the Socket process is alive before attempting to send. If the send itself fails (for example, the Socket process dies between the alive check and the send), the Connection must still reply with an error and must not leave a dangling entry in the pending map. Note that this error is returned as a normal GenServer reply (not an exit), so the Dispatcher receives it as the return value of `GenServer.call` and passes it through. The implementation should check the Socket PID first, attempt the send, and only insert into the pending map after confirming the send succeeded — this ordering prevents dangling entries.

### Timeout and Stale Pending Entries

There is a race between the caller's GenServer.call timeout and a late-arriving result. When a caller times out, OTP delivers an exit to the caller, but the `from` and its pending map entry remain in the Connection's state. A result arriving after the timeout will find the entry, call `GenServer.reply/2` on the already-dead caller (which is a silent no-op), and `Map.pop` will remove the entry. This means the pending map is self-cleaning in the normal case.

However, if the agent never responds at all (no result frame ever arrives), the pending entry leaks permanently. To guard against this, the Connection should schedule a delayed message to itself for each pending command (using `Process.send_after` with the command's timeout plus slack). The pending map value should store both the caller's `from` reference and the timer reference returned by `Process.send_after`, so that the timer can be cancelled when a result arrives normally. When the timeout message arrives, if the command ID is still in the pending map, the Connection pops it, cancels (or ignores) the timer reference, and replies with `{:error, :timeout}`. This ensures entries cannot accumulate indefinitely even if the agent silently drops commands.

The timeout message sent via `Process.send_after` must include the command ID so the `handle_info` clause can look up the correct pending entry. A bare timeout atom without a command ID would be ambiguous when multiple commands are pending simultaneously.

The slack on the server-side timeout guard should be slightly longer than the slack on the GenServer.call timeout (for example, 10 seconds versus 5 seconds) so that in normal operation, the caller-side timeout fires first and the server-side guard only fires for true no-response cases.

The Connection must pass the resolved timeout (in seconds) to the dispatch call, or the Dispatcher must pass it along when invoking the Connection. The Connection needs this value to compute the server-side timeout guard delay. The dispatch function signature should be `dispatch(pid, command_id, command)` where the `command` map includes the `:timeout` field (already resolved by the Dispatcher with the default applied). The Connection reads the timeout from the command map to schedule its guard timer.

### Cancellation on Disconnect

When the Connection GenServer terminates (for any reason — clean shutdown, agent disconnect, or unexpected crash), its `terminate/2` callback iterates over all entries in the pending map and replies with `{:error, :agent_disconnected}` to each. It also cancels any outstanding timer references to avoid sending timeout messages to a dead process. This ensures no caller can hang past a dropped connection. The `:agent_disconnected` error is used for all termination reasons because, from the caller's perspective, the effect is the same: the agent is no longer reachable through this Connection.

The `terminate/2` callback must be defensive: if the pending map is empty, it should be a no-op. If the Connection's state is malformed for any reason (for example, if an earlier callback crashed partway through a state update), the terminate callback should not itself crash — it should make a best-effort attempt to reply to whatever pending entries it can find.

For `terminate/2` to be reliably called, the Connection process must be trapping exits (via `Process.flag(:trap_exit, true)` in `init/1`). The implementer should verify that SPEC-3's Connection implementation already traps exits. If it does not, this must be added as part of this spec's implementation.

### Command ID Generation

Command IDs are generated server-side using 12 bytes of cryptographic randomness, base64url-encoded without padding, producing a 16-character string. The agent never generates IDs — it just echoes the string from `execute` into `result`. The generation function should live in the Dispatcher module (or a small helper it calls) so tests can verify the format independently.

The generation function should use Erlang's `:crypto.strong_rand_bytes/1` for the random bytes and Elixir's `Base.url_encode64/2` with `padding: false` for the encoding.

### Telemetry Hooks

The dispatcher emits two telemetry events that SPEC-6 (Audit) and SPEC-7 (Observability) will subscribe to:

- `[:ex_code_remote, :dispatcher, :command, :start]` — with system time and metadata containing machine name, command ID, and command type.
- `[:ex_code_remote, :dispatcher, :command, :stop]` — with duration and metadata containing machine name, command ID, command type, and final status (including error cases like `:timeout` and `:agent_disconnected`).

The `:start` event measurements should contain `system_time` (from `System.system_time()`). The `:stop` event measurements should contain `duration` (the monotonic time elapsed since the `:start` event, computed using `System.monotonic_time()` captured at the start and subtracted at the stop). The Dispatcher must capture the monotonic start time at the same point it captures the system time for the `:start` event, to ensure duration accuracy.

The `:stop` event must be emitted for every `:start` event, regardless of outcome. This means the Dispatcher is responsible for emitting `:stop` even when the dispatch fails with a timeout or disconnect — not just on successful results. This invariant is important for downstream consumers that pair start/stop events.

The metadata for both events includes the same set of identifying fields (machine name, command ID, command type) so consumers can correlate them. Because the command ID is generated before the `:start` event is emitted, both events always carry the same non-nil command ID for a given dispatch attempt. The `:stop` metadata additionally includes a `status` field that is either `:ok`, `:timeout`, `:agent_disconnected`, or `:not_connected`.

The metadata map should use these specific keys: `machine` (string), `command_id` (string), `command_type` (atom, or `nil` if the command map did not contain a `:type` key), and for `:stop` events, `status` (atom). These keys are a contract — SPEC-6 and SPEC-7 will pattern-match on them.

The `:not_connected` status covers two distinct failure paths: the Registry lookup failing (no Connection PID found) and the Connection's Socket being dead at send time (Connection replies with an error). Both produce the same status in the telemetry event. Consumers that need to distinguish them can check whether a duration measurement is present — the Registry-failure path short-circuits before the GenServer.call, while the Socket-dead path includes round-trip time to the Connection.

These are hooks, not business logic. The dispatcher works without any subscribers.

## How to Evaluate

### Success Criteria

**Product-level outcomes:**

- [ ] Commands dispatched through the new path complete without user-visible delay attributable to the dispatch layer itself — the latency budget is spent on agent execution, not on coordination overhead. Concretely, the dispatch layer's contribution to round-trip time should be under 10ms for a locally-connected agent, compared to the Python version's 500ms minimum.
- [ ] When an agent disconnects mid-command, every waiting caller receives a definitive error within seconds, not after a timeout — the user is never left wondering whether their command is still running
- [ ] The dispatch path has no failure mode that causes a caller to hang indefinitely — every dispatch resolves to either a result or an explicit error
- [ ] After deployment, the telemetry events emitted by this spec provide enough data to confirm these outcomes in production. Specifically, the duration measurements on `:stop` events for successful dispatches should show that coordination overhead is negligible relative to agent execution time, and every `:start` event should have a matching `:stop` event (no unpaired events, which would indicate a caller that never resolved).

**Technical verification:**

- [ ] `Dispatcher.run/2` returns `{:error, :not_connected}` for unknown machines
- [ ] `Dispatcher.run/2` returns `{:error, :not_connected}` when the Connection is alive but its Socket has died (send failure path)
- [ ] `Dispatcher.run/2` against a connected agent sends an `execute` frame and blocks until the matching `result` arrives
- [ ] The result map returned on success contains `status`, `output`, `error`, and `exit_code` with the correct types described in the Public API section
- [ ] Round-trip latency for a no-op command is under 10ms in local test runs (wall-clock time from `Dispatcher.run/2` call to return, with a FakeAgent that responds immediately), compared to 500ms minimum in the Python version. This threshold validates that the polling loop is gone; if the test proves flaky in CI due to scheduling jitter, the ceiling may be relaxed to 50ms without undermining the assertion — the point is to prove sub-polling-interval latency, not to benchmark raw throughput.
- [ ] When `timeout` is not supplied in the command map, the Dispatcher uses the default of 60 seconds and the GenServer.call deadline reflects the default plus slack
- [ ] Pending callers are unblocked with `{:error, :agent_disconnected}` when the Connection terminates
- [ ] Unknown/duplicate result IDs are silently ignored without crashing the Connection or corrupting pending state
- [ ] Malformed result frames (valid JSON but missing or incorrectly-typed fields) are discarded without crashing the Connection, leaving the pending entry for the server-side timeout guard to clean up
- [ ] Caller timeout is respected and exceeds `command.timeout` by at least 5s of slack
- [ ] When the agent never responds, the pending entry is cleaned up by the server-side timeout guard rather than leaking indefinitely
- [ ] Telemetry `:start` and `:stop` events are emitted for every dispatch, including failures
- [ ] The `:stop` event is emitted even when the dispatch ends in `:timeout` or `:agent_disconnected`
- [ ] Telemetry `:start` and `:stop` events are both emitted when the machine is not found in the Registry, and the command ID is the same non-nil value in both events
- [ ] A `:noproc` exit from GenServer.call (Connection died between lookup and call) is caught and returned as `{:error, :not_connected}` rather than crashing the caller
- [ ] The server-side timeout guard cancels its timer when a result arrives normally, rather than leaving timers running unnecessarily
- [ ] The pending map stores timer references alongside `from` references, and both are cleaned up on result, timeout, and disconnect
- [ ] Generated command IDs are exactly 16 characters, contain only URL-safe base64 characters (alphanumeric, hyphen, underscore), and are unique across calls
- [ ] The `terminate/2` callback is exercised by killing the Connection while callers are pending, and all callers receive `{:error, :agent_disconnected}` rather than an exit signal
- [ ] The Dispatcher's exit-catching logic handles unexpected exit reasons (not just `:timeout` and `:noproc`) without crashing

### FakeAgent Test Helper

The FakeAgent is a reusable test support module that lives in a shared test support directory (such as `test/support/`). It connects to the server via a WebSocket client library, performs the agent handshake defined in SPEC-3 (registering under a given machine name), and handles incoming `execute` frames by invoking a caller-provided response function.

The FakeAgent needs a WebSocket client library available in the test environment. The project already has `mint_web_socket` in its dependencies, which can serve as a WebSocket client. If `mint_web_socket` is not suitable as a client (it may only provide server-side functionality), the implementer should evaluate alternatives such as `websocket_client` or `gun` and add one as a test-only dependency. The implementer should verify the chosen library can initiate outbound WebSocket connections and send/receive text frames.

The FakeAgent should be implemented as a GenServer (or similar process) that owns the WebSocket connection. It should accept configuration at start time: the server URL, the machine name to register as, the test process PID to forward frames to, and the response function. The start function should return only after the handshake is complete, so that tests can immediately dispatch commands after starting the FakeAgent without race conditions.

The test support directory (`test/support/`) must be added to the compilation paths in `mix.exs` (under the `:test` environment's `elixirc_paths`) if it is not already configured. The implementer should verify this.

The response function receives the full `execute` frame as its argument, so it can inspect the command ID, command type, and other fields to decide how to respond. This is important for concurrent dispatch tests where the FakeAgent must correlate responses to specific commands.

The FakeAgent must support at least these behaviors, controlled by the response function passed at creation time:

- **Immediate response:** Receives an `execute` frame and immediately sends back a `result` frame with `status: "completed"` and caller-specified output.
- **Delayed response:** Waits a configurable duration before sending the result. Used to test that the system behaves correctly when responses arrive just before or just after timeouts.
- **No response:** Receives the `execute` frame but never sends a result. Used to test the server-side stale-entry cleanup.
- **Unrecognized ID response:** Sends a `result` frame with a command ID that does not match any pending command. Used to test the unknown-ID path.
- **Disconnect before responding:** Closes the WebSocket connection after receiving the `execute` frame but before sending a result. Used to test the disconnect cancellation path.
- **Malformed response:** Sends a `result` frame that is valid JSON but omits required fields (for example, missing `status` entirely, or sending `output` as a number instead of a string). Used to test the Connection's defensive parsing.

The FakeAgent should forward received frames to a designated test process (typically the test's own PID, passed at creation time) so that tests can use standard `assert_receive` to verify what was sent to the agent. This is preferable to storing frames in ETS or an Agent process because it integrates with ExUnit's built-in message assertion helpers and avoids shared mutable state between tests.

The FakeAgent should also provide a way to change its response function after creation, to support tests that need different behaviors in sequence (for example, responding to the first command normally and then disconnecting on the second). This can be a simple `set_response_function/2` call.

The FakeAgent must be started under the test's supervision (using `start_supervised!/2` or an explicit `on_exit` callback that stops the process) to guarantee cleanup. A leaked FakeAgent process holding a WebSocket connection would leave a stale entry in the Agent Registry, causing subsequent tests to see unexpected state.

The FakeAgent is not just test infrastructure for this spec — it is shared test infrastructure for the entire port. SPEC-5 (MCP Tools), SPEC-6 (Audit), and any future spec that exercises the dispatch path will reuse this helper. The investment here pays compound returns across the remaining implementation work.

### Tests

Tests should be included with the implementation changes. All tests should be tagged with `@moduletag` or `@tag` so they can be run in isolation during development (for example, `@tag :dispatcher`).

- **Dispatcher against unknown machine** returns `{:error, :not_connected}`.
- **Dispatcher against a connected FakeAgent** that echoes a `completed` result returns `{:ok, result}` with expected fields. The test should verify that the result map contains `status`, `output`, `error`, and `exit_code` with the correct values and types from the FakeAgent's response.
- **Round-trip latency** is under 10ms (using timer measurement). See the note in the success criteria about CI tolerance — if this test proves flaky on shared CI runners, the threshold may be raised to 50ms without invalidating the assertion.
- **Default timeout applied** — dispatching a command with no `timeout` field in the command map should use the default timeout. This can be verified indirectly by confirming the dispatch does not fail with an arithmetic or nil-reference error when timeout is omitted, and more directly by observing the GenServer.call deadline if the test framework allows it.
- **Command ID format** — the generated command ID is exactly 16 characters and contains only URL-safe base64 characters. This can be tested by calling the generation function directly, independent of any dispatch. The test should generate multiple IDs and verify they are all unique.
- **Telemetry events** `:start` and `:stop` are captured in order with matching command IDs. Use a telemetry handler attached in test setup that captures events to a test process's mailbox. The handler must be detached in the test's `on_exit` callback to avoid leaking handlers between tests.
- **Telemetry on failure** — `:stop` is emitted with error status when the dispatch times out or the connection drops.
- **Telemetry on not_connected** — `:start` and `:stop` are both emitted even when the machine is not found in the Registry. The command ID in both events should be the same non-nil value. The `:stop` metadata should have `status: :not_connected`.
- **Telemetry duration** — the `:stop` event contains a `duration` measurement that is a non-negative integer.
- **Connection terminate with pending callers** — all callers receive `{:error, :agent_disconnected}`. This test should have multiple concurrent callers waiting on the same Connection, then kill the Connection and assert that every caller receives the disconnect error. The test should spawn at least three concurrent callers using `Task.async` or similar, ensure they are all blocked on the Connection, then terminate the Connection and collect all results.
- **Unknown result ID** — a result frame with an unrecognized command ID does not crash the Connection or affect pending state. After sending the unknown result, dispatch a real command and verify it succeeds normally.
- **Malformed result frame** — a result frame that is valid JSON but missing required fields (such as `status`) does not crash the Connection. The pending entry for the affected command should remain in the map and eventually be cleaned up by the server-side timeout guard. The test should verify the Connection process is still alive and can successfully handle subsequent normal dispatches after receiving the malformed frame.
- **Caller timeout** — when the FakeAgent does not respond and the command timeout elapses, the caller receives `{:error, :timeout}` and the pending map entry is cleaned up. Use a short timeout (such as 100ms) to keep the test fast. The test must verify the return value is `{:error, :timeout}` specifically, not a raw exit.
- **Server-side timeout guard** — when the FakeAgent never responds and enough time passes, the server-side guard fires and cleans up the pending entry. This is distinct from the caller timeout test: here the test should verify the Connection's internal state is clean after the guard fires, not just that the caller got an error. The test can check the pending map size by calling a Connection introspection function or by dispatching a subsequent command that succeeds.
- **Late result after timeout** — when the FakeAgent responds after the caller has timed out, the Connection handles the result gracefully (no crash, no error log) and the pending map does not leak. The test should verify the Connection process is still alive and functional after receiving the late result.
- **Concurrent dispatches** — multiple callers dispatching to the same agent concurrently each receive their own correlated result without cross-talk. At least three concurrent dispatches should be tested to exercise the map-based correlation under contention. The FakeAgent's response function should use the command ID from each `execute` frame to produce distinct results, so the test can verify each caller received its own response. The test should use `Task.async_stream` or similar to dispatch all commands concurrently and collect results, then match each result to its originating command.
- **Connection dies between Registry lookup and GenServer.call** — the Dispatcher catches the `:noproc` exit and returns `{:error, :not_connected}`. This test should register a Connection PID in the Registry, kill the Connection process, and then call `Dispatcher.run/2` with that machine name before the Registry has cleaned up the stale entry.
- **Socket dead while Connection alive** — when the Connection's Socket process has died but the Connection itself is still running, dispatching a command returns `{:error, :not_connected}` from the Connection's send-failure path (not from a GenServer exit). This is distinct from the `:noproc` test and exercises the Connection's alive-check logic. The test should kill the Socket process directly and then dispatch a command.
- **FakeAgent frame inspection** — at least one test should verify that the `execute` frame sent to the FakeAgent matches the expected wire format from SPEC-2 (correct field names, correct command ID, correct command type). The test should assert on the specific string keys and value types in the JSON frame, not just that a frame was received.

### Validation

- `mix test` passes
- `mix test --only dispatcher` passes (assuming the tag described above)
- Manual: with the Python agent connected and running on a reachable machine, use an IEx session to call `Dispatcher.run/2` with a shell command and observe the result immediately. This requires the Python agent to be compatible with the wire protocol defined in SPEC-2 — if the Python agent has not been updated to match the new frame format, this manual test cannot be performed, and the implementer should note that as a blocker for manual validation.

## Task Decomposition

This section describes the discrete implementation tasks within this spec and their dependencies on each other. Tasks that do not depend on each other can be worked in parallel.

**Task 1: Command ID generation.** Implement the function that generates a 16-character URL-safe random string from 12 bytes of cryptographic randomness. This is a pure function with no dependencies on other tasks and can be built and tested in isolation. The test should verify the format (length, character set) and uniqueness across multiple calls.

**Task 2: FakeAgent test helper.** Build the FakeAgent module in the shared test support directory. This requires the WebSocket endpoint and agent handshake from SPEC-3 to be working, but does not depend on any other task in this spec. The FakeAgent is needed by all subsequent test tasks, so it should be built early. This task includes verifying that a WebSocket client library is available in the test dependencies and adding one if needed, and verifying that `test/support/` is in the `elixirc_paths` for the test environment.

Acceptance criteria for this task:
- FakeAgent can connect to the server and complete the handshake under a given machine name
- FakeAgent forwards received `execute` frames to a test process
- FakeAgent sends `result` frames according to its response function
- FakeAgent supports the malformed-response behavior for defensive parsing tests
- FakeAgent can be started and stopped cleanly within a test without leaking processes (verified by using `start_supervised!/2` or an explicit `on_exit` cleanup callback)
- At least one smoke test verifies the FakeAgent connects, receives a frame, and sends a response

**Task 3: Connection GenServer changes.** Modify the Connection GenServer to handle the dispatch call (stashing `from` and timer reference in the pending map, building and sending the `execute` frame via the SPEC-2 codec), handle inbound `result` frames (looking up and popping the pending entry, cancelling the timer, replying to the caller), handle the server-side timeout guard message (which must include the command ID so the correct pending entry is found), handle send failures (replying immediately with an error when the Socket is dead), and handle disconnect cleanup in `terminate/2`. This task depends on the pending map stub from SPEC-3 and the wire format from SPEC-2. It is the largest single task in this spec.

This task breaks down into the following subtasks, which should be implemented in order:

- **3a: Verify prerequisites.** Read the Connection module and confirm: the pending map exists in state, `terminate/2` is defined, `Process.flag(:trap_exit, true)` is called in `init/1`, and the Socket send mechanism is understood. Document any gaps that need to be fixed.
- **3b: Dispatch handle_call.** Add the `handle_call` clause for dispatch. Implement the Socket alive check, frame building via SPEC-2 codec, send, pending map insertion (with both `from` and timer reference), and `:noreply` return. Implement the send-failure path that replies with `{:error, :not_connected}`.
- **3c: Result handle_info.** Add or modify the `handle_info` clause that processes inbound `result` frames. Look up command ID in pending map, pop entry, cancel timer, build result map via codec, reply to caller. Silently ignore unknown IDs. This clause must be defensive against malformed result frames — if the codec returns an error when parsing the result, the frame should be discarded without crashing the Connection.
- **3d: Timeout guard handle_info.** Add the `handle_info` clause for the server-side timeout message. Match on command ID, check pending map, pop and reply with `{:error, :timeout}` if still present.
- **3e: Terminate cleanup.** Modify `terminate/2` to iterate pending map, reply `{:error, :agent_disconnected}` to all, cancel all timers.

**Task 4: Dispatcher module.** Implement `Dispatcher.run/2` with command ID generation, telemetry emission, Registry lookup, default timeout resolution, GenServer.call with timeout, exit catching, and error passthrough. This depends on Task 1 (command ID generation) and Task 3 (Connection GenServer changes). It is a thin orchestration layer and should be straightforward once the Connection changes are in place.

Acceptance criteria for this task:
- `run/2` resolves the machine name via Registry and returns `{:error, :not_connected}` if not found
- `run/2` catches all exit types from GenServer.call and returns appropriate error tuples
- `run/2` emits paired telemetry `:start` and `:stop` events for every call, including failures
- The default timeout module attribute is defined and used when the command map omits `:timeout`
- The GenServer.call timeout includes the five-second slack converted to milliseconds

**Task 5: Tests.** Write the full test suite described above. This depends on Task 2 (FakeAgent), Task 3 (Connection changes), and Task 4 (Dispatcher module). Some tests (such as the command ID format test) can be written alongside their respective tasks.

Tests should be organized into describe blocks by category: basic dispatch, timeout behavior, disconnect and cancellation, concurrent dispatch, telemetry, edge cases, and defensive parsing. Each test should be self-contained and not depend on ordering or shared state from other tests.

## Known Limitations

This section documents constraints accepted for the current scope, along with the conditions under which each would need to be revisited.

**No backpressure or admission control.** The pending map, associated timers, and blocked caller processes all grow without bound under sustained load with a slow agent. This is acceptable for the current use case — interactive MCP tool invocations are human-rate-limited and unlikely to exceed single-digit concurrent commands per agent.

This limitation should be revisited if any of the following conditions become true: the system is extended to support batch or programmatic dispatch (not human-initiated); agents are shared across multiple concurrent users; or monitoring (SPEC-7) reveals that pending map sizes in production regularly exceed low double digits. At that point, a maximum pending count or admission control mechanism should be added to the Connection. The pending map is the pressure point — it is where unbounded growth would manifest first.

**No retry logic.** Failed dispatches surface as errors to the caller. The Dispatcher is a transport layer and does not attempt to recover from failures. Retry policy, if ever needed, belongs in the MCP tool handlers (SPEC-5) or a higher-level orchestration layer, where the semantics of the command (idempotent or not) can inform the decision.

## Notes

- The biggest risk in this spec is a subtle leak in the pending map: if a result never arrives (agent drops the command), the server-side timeout guard described in the "Timeout and Stale Pending Entries" section is the mitigation. Without it, a misbehaving agent could cause unbounded memory growth in the Connection process.
- A less obvious risk is a malformed result frame crashing the Connection GenServer. Because the Connection owns the pending map for all in-flight commands, a crash caused by one bad frame kills the process and delivers `{:error, :agent_disconnected}` to every pending caller — collateral damage from a single bad response. The defensive parsing requirement in this spec mitigates this, but the implementer should pay particular attention to the SPEC-2 codec's error handling to ensure it returns error tuples rather than raising on unexpected input.
- Telemetry is a standalone library included by most Elixir projects. The `:telemetry` library is already present in the project's `deps/` directory. The implementer should verify it is a direct dependency in `mix.exs`.
- SPEC-5 (MCP tools) is the first caller of `Dispatcher.run/2`, so the public API must be stable before that spec is written.
- The FakeAgent test helper should live in a shared test support directory so SPEC-5 and later specs can import it without duplication.
- The Dispatcher must catch exits from `GenServer.call` rather than letting them propagate. A timed-out or crashed Connection should not crash the calling process (which will be an MCP tool handler in SPEC-5).
- The pending map value is not just the `from` reference — it is a tuple (or small map) containing both the `from` reference and the timer reference. This is important for the implementer to get right; storing only `from` will lead to timer leaks.
- When building the `execute` frame in the Connection, the implementer should use the wire protocol codec from SPEC-2 (if one exists) rather than reimplementing the atom-to-string key conversion. If SPEC-2 does not provide a shared codec module, one should be extracted during this spec's implementation so the encoding logic lives in one place.
- The Dispatcher does not validate that the command `type` is one of the four known types. An unrecognized type will be sent to the agent as-is. This is deliberate — the Dispatcher is a transport layer, not a validation layer — but it means a typo in the command type will only fail at the agent, not at dispatch time.
- This spec is the critical path for the entire port's value proposition. If the dispatch layer is unreliable or slow, no amount of polish in the MCP tools (SPEC-5), audit system (SPEC-6), or other downstream specs will recover the user experience. The bar for correctness and test coverage here should be treated accordingly.
- The implementer should run the existing test suite (`mix test`) before starting work to confirm a green baseline, and should run it after each subtask to catch regressions early.
- The order of operations in the dispatch `handle_call` (check Socket alive, send frame, then insert into pending map) is load-bearing. Inserting into the pending map before confirming the send succeeded creates a window where a dangling entry exists with no possibility of a matching result. The implementer must preserve this ordering.

## Observations

- [decision] In-memory `command_id => from` map on the owning Connection GenServer — the canonical BEAM pattern for request/response over a long-lived socket
- [decision] Dispatcher is a plain module, not a process — no bottleneck, no mailbox contention, and the Connection is the only stateful actor
- [decision] Server generates command IDs, agent echoes them — agent remains dumb, wire format matches existing Python agent
- [decision] Disconnect cancels pending callers via `terminate/2` — no caller can hang past a dropped connection
- [decision] Telemetry events are emitted as hooks, consumers decided later — dispatcher has no runtime dependency on audit or metrics
- [decision] Server-side timeout guard cleans stale pending entries — prevents unbounded memory growth from unresponsive agents
- [decision] Pending map values store both `from` and timer references — ensures clean cancellation on all paths
- [decision] Error taxonomy is small, stable, and caller-friendly — three error reasons give downstream MCP handlers everything they need to produce clear user-facing messages without coupling to dispatch internals
- [decision] Command ID generated before telemetry start — both events in a pair always share the same non-nil ID, making consumer correlation trivial
- [decision] No ordering guarantees on command execution — the Dispatcher is a transport layer and does not serialize commands to the same agent
- [decision] Insert into pending map only after successful send — prevents dangling entries when the Socket is dead
- [decision] Defensive result-frame parsing — a malformed response from one command must not crash the Connection and take down all other pending callers
- [decision] Known limitations documented with trigger conditions — backpressure and retry decisions are deferred deliberately, not overlooked
- [anti-pattern] Polling a database for state the WebSocket already delivered — this is the Python version's core bug, specifically not reproduced
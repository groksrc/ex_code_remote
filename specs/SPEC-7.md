---
title: 'SPEC-7: Observability'
type: spec
permalink: specs/spec-7-observability
tags:
- observability
- telemetry
- logging
- metrics
---

# SPEC-7: Observability

## Why

The Python server accumulated an event-loop stall watchdog, per-session duration logging, disconnect reason tracking, and PYTHONUNBUFFERED=1 — all because something was going wrong that the operator couldn't see. The BEAM equivalent of "event loop is stalled" doesn't exist (preemptive scheduling), but operators still need answers to: how long are commands taking, are agents reconnecting too often, is the dispatcher piling up pending work?

Rather than hand-rolled log lines, this spec defines a **telemetry event contract** that downstream consumers (logs, metrics, dashboards) can subscribe to. It formalizes the events already emitted by prior specs and adds new ones for agent lifecycle and HTTP request timing.

The entire port exists because users experience flakiness — commands timing out, agents silently disconnecting, work disappearing. Observability is the mechanism for proving the new server is better. During the SPEC-8 bake-off, structured logs are the primary diagnostic tool: the operator watches disconnect frequency, command latency, and error rates to decide whether to retire the Python server or roll back. If the telemetry output cannot answer those three questions clearly, the bake-off cannot produce a confident verdict and the port stalls. This spec is not infrastructure for its own sake — it is the evidentiary foundation for the go/no-go decision on the entire project.

## What

**Dependencies:** SPEC-4 (dispatcher telemetry events already emitted) and SPEC-3 (connection lifecycle, currently uses Logger.info for lifecycle events). This spec extends both with formal telemetry. SPEC-6 (audit) also attaches handlers to dispatcher events — see the coordination section below.

**In scope:**

- A documented list of all telemetry events emitted across the codebase, including those already emitted by SPEC-4
- `ExCodeRemote.Telemetry` module that attaches a handler and emits structured log lines (JSON) for each event
- Logger configuration for JSON formatting in production, human-readable in dev
- A minimal `ExCodeRemote.Telemetry.Metrics` module that defines Telemetry.Metrics specs — not wired to a reporter yet, but ready for SPEC-8 to plug one in
- New telemetry events added to Connection (agent lifecycle) and Router (HTTP timing)
- Removal of the ad-hoc Logger.info calls in the SPEC-3 Connection module that are superseded by the new telemetry events — these must be removed, not kept alongside telemetry, to avoid duplicate log output for the same lifecycle transitions

**Out of scope:**

- LiveDashboard (drags in Phoenix LiveView for a headless service)
- Prometheus / StatsD / OpenTelemetry reporters — the reporter choice lands in SPEC-8 or later
- Distributed tracing
- Custom log backends

## Event Contract

All events are under the `[:ex_code_remote, …]` namespace.

Each event category maps to a specific operator question. The dispatcher events answer "how long are commands taking and are they succeeding?" The agent connection events answer "are agents reconnecting too often and are commands being orphaned?" The HTTP events answer "is the server responsive and what is the request profile?" These are the same questions the SPEC-8 bake-off needs answered to evaluate stability.

### Dispatcher Events (already emitted by SPEC-4)

These events are defined and emitted in SPEC-4. This spec documents them as part of the unified contract and wires the Telemetry log handler to them. SPEC-6 (audit) also subscribes to these events.

| event | measurement | metadata |
|---|---|---|
| `[:ex_code_remote, :dispatcher, :command, :start]` | `system_time` | `machine`, `command_id`, `type` |
| `[:ex_code_remote, :dispatcher, :command, :stop]` | `duration` (native time units) | `machine`, `command_id`, `type`, `status` |
| `[:ex_code_remote, :dispatcher, :command, :exception]` | `duration` | `machine`, `command_id`, `type`, `kind`, `reason`, `stacktrace` |

### Agent Connection Events (added by this spec)

These events are added to the Connection GenServer in this spec, replacing the Logger.info calls from SPEC-3. The existing Logger.info calls for connect, disconnect, and replacement must be removed once the corresponding telemetry events are in place.

| event | measurement | metadata |
|---|---|---|
| `[:ex_code_remote, :agent, :connected]` | `system_time` | `machine` |
| `[:ex_code_remote, :agent, :disconnected]` | `duration` (session length, native) | `machine`, `reason`, `pending_count` |
| `[:ex_code_remote, :agent, :replaced]` | `system_time` | `machine`, `old_pid` (emitted when a reconnect supplants a previous connection) |

The `pending_count` in the `:disconnected` event is the number of commands that were awaiting a response from this agent at the time of disconnect. The Connection GenServer already tracks its own in-flight commands; use that count directly rather than querying the Dispatcher.

The `pending_count` is the single most important diagnostic signal in the agent events. A disconnect with `pending_count: 0` is routine — the agent went away cleanly. A disconnect with `pending_count: 3` means three commands just became orphans and three users are about to see a timeout or error. During the bake-off, a pattern of nonzero `pending_count` disconnects is a red flag that the port has not solved the reliability problem.

The `reason` field in the `:disconnected` event should be an atom describing the disconnect cause (for example, `:normal`, `:remote`, `:timeout`, `:replaced`). If the underlying reason from `terminate/2` is not already an atom, normalize it to one from a fixed set so that downstream consumers can match on it without dealing with arbitrary terms. If the reason does not match any known category, use `:unknown`.

The `old_pid` field in the `:replaced` event is included for diagnostic logging only. It must not be used as a tag in any metric definition, since PIDs are ephemeral and unbounded. The Metrics module must not reference this field.

**Event shape asymmetry note:** Unlike the dispatcher events, agent connection events do not include `:start`/`:stop`/`:exception` spans. The connection lifecycle is modeled as discrete state transitions (connected, disconnected, replaced) rather than timed operations. The session duration is captured as a measurement on the `:disconnected` event instead. This is intentional — there is no meaningful "start" event for a session that would need to be correlated with a "stop."

### HTTP Events (added by this spec)

Added via a module Plug in the router pipeline that times each request.

| event | measurement | metadata |
|---|---|---|
| `[:ex_code_remote, :http, :request, :stop]` | `duration` | `method`, `route`, `status` |

**Why no `:start` event for HTTP:** The timing Plug captures the start timestamp internally and only emits the `:stop` event with the computed duration. A separate `:start` event would add overhead to every request and provide limited value — the start time is implicit in the stop event's timestamp, and there is no use case for correlating a start event with a stop event at the telemetry level (that is what distributed tracing would provide, which is out of scope).

The `route` metadata field must be the matched route pattern (for example, `/api/machines/:machine/commands`), not the raw request path. Using the raw path would create unbounded cardinality in any downstream metrics consumer, since paths contain dynamic segments like machine names and command IDs. If the matched route pattern is not available (for example, on a 404), use a fixed string such as `"unmatched"`.

The `method` field should be an uppercase string (for example, `"GET"`, `"POST"`). The `status` field should be an integer HTTP status code.

The route pattern is available from `conn.private[:plug_route]` after the router has matched the request. Since the timing Plug is placed before routing, the `before_send` callback is the correct place to read this value — by the time `before_send` fires, routing has completed and the value is populated. If `conn.private[:plug_route]` is nil (no route matched), use `"unmatched"`.

## How (High Level)

### Telemetry Handler

`ExCodeRemote.Telemetry` attaches to all events listed above at application start. The attachment must happen in `Application.start/2`, before any requests can be served or connections accepted. Each event is logged as a structured JSON object containing the event name, measurements (with duration converted to milliseconds), and metadata.

The handler must use a distinct handler ID (for example, `"ex-code-remote-telemetry-logger"`) that does not collide with any other handler in the system, including the SPEC-6 audit handler. This ID is what allows the handler to be attached and detached independently.

The `attach/0` function should attach a single handler to the full list of events (using `:telemetry.attach_many/4`), not one handler per event. This keeps the attachment count low and simplifies management.

After attaching, the module should log an info-level message confirming the telemetry handler was attached successfully, including the count of events subscribed. This gives operators a startup signal in the deploy logs — during the bake-off, seeing this line confirms observability is live. Its absence after a restart is an immediate red flag.

Sensitive fields (`content`, `auth_token`) are dropped from metadata before logging. This scrub list should be defined as a module attribute so it is easy to extend as new sensitive fields are introduced. Oversized string values are truncated to 200 bytes. For multi-byte (UTF-8) strings, truncation must not split a character — truncate to the last complete codepoint at or before the 200-byte boundary. Non-string values in metadata (atoms, numbers, booleans, nil) should be passed through without truncation. Lists and maps in metadata should be passed through as-is — do not attempt to recursively truncate nested structures, as metadata is expected to be shallow.

The `stacktrace` field in `:exception` events should be formatted as a string (using `Exception.format_stacktrace/1`) before logging, since raw stacktrace tuples are not meaningful in JSON output.

**Log levels:** The handler should log `:start` and `:stop` events at the `:info` level, `:exception` events at the `:error` level, `:connected` and `:replaced` at `:info`, `:disconnected` at `:warning` (since a disconnect may warrant attention, especially with a nonzero `pending_count`), and HTTP `:request` `:stop` events at `:info`. Operators can suppress verbose HTTP request logging in production by raising the minimum log level for the telemetry handler's log calls, but the default should be `:info` so that all events are visible out of the box.

**Handler crash resilience:** The `:telemetry` library silently detaches any handler that raises an exception. This means a single unexpected metadata shape or encoding error would cause all subsequent events to be silently lost. The handler function must wrap its body in a rescue clause that logs the failure at the `:error` level (using the standard Logger, not telemetry) and returns `:ok`, so the handler remains attached. The rescue log line should include the event name and the exception message so the operator can diagnose what went wrong. This is critical — a detached telemetry handler produces no error and no events, making it very difficult to diagnose.

### Logger Config

In production, use a JSON log formatter (such as `logger_json`) so logs can be piped into `jq` or ingested by a log aggregator. In dev, keep the default human-readable formatter. This split is configured in `runtime.exs`. The `logger_json` dependency should be added with `only: :prod` if possible, or unconditionally if the formatter needs to be available for testing prod-like config.

If the JSON formatter is added unconditionally, ensure it does not interfere with `ExUnit.CaptureLog` during tests. The test environment must continue to use the default Elixir log formatter so that captured log assertions remain simple string matches. Configure this explicitly in `config/test.exs` if necessary.

If `logger_json` is added unconditionally to deps, `config/test.exs` must explicitly set the console backend formatter to the default Elixir formatter to guarantee isolation from the prod JSON formatter configuration.

### Metrics Definitions

`ExCodeRemote.Telemetry.Metrics` exports a single public function, `metrics/0`, that returns a flat list of `Telemetry.Metrics` structs. This is the interface SPEC-8 will use to wire up a reporter — the reporter module calls `Metrics.metrics/0` and passes the result to its supervisor.

The metrics defined should include: counters for commands dispatched (tagged by `machine`, `type`, and `status`), distributions for command duration, counters for agent connections and disconnections (tagged by `machine` and `reason`), counters plus distributions for HTTP requests (tagged by `method`, `route`, and `status`).

Each duration metric must declare its unit conversion explicitly (for example, `unit: {:native, :millisecond}`) so that reporters display human-readable values regardless of the native time unit on the host platform.

Cardinality note: `machine` is bounded by the number of registered agents (expected to be small, on the order of tens). `route` is bounded by the number of defined routes (must use the route pattern, not the raw path — see the HTTP events section above). `status` for HTTP should be the integer status code; for commands, it is the result atom from SPEC-4. These tag sets are safe for metric backends without further aggregation. The `old_pid` field from the `:replaced` event must not appear as a tag in any metric — it is unbounded.

These are **definitions only** in this spec — no reporter is started. SPEC-8 can pick a reporter when deploying. Note that SPEC-8 also defers reporter wiring, so the Metrics module will not deliver runtime value during the initial bake-off. Its value is reducing the cost of adding monitoring later — when the time comes to wire Prometheus or StatsD, the metric definitions are already reviewed, tested, and co-located with the events they describe.

### Dependencies

Telemetry (`~> 1.2`) is likely already a transitive dependency via Bandit/ThousandIsland, but should be listed explicitly in `mix.exs` to pin the minimum version. Add `telemetry_metrics` (`~> 1.0`) and a JSON log formatter (such as `logger_json ~> 6.0`) to deps.

After adding dependencies, run `mix deps.get` and verify that the new versions do not conflict with existing transitive dependencies (particularly the telemetry version already pulled in by Bandit). If there is a conflict, prefer the version range that satisfies both the explicit and transitive requirements.

### Changes to Existing Code

- **Dispatcher (SPEC-4):** Already emits telemetry events via `:telemetry.span/3`. No changes needed. Verify that the metadata keys emitted by the dispatcher match the contract table above — if SPEC-4's implementation diverges from the contract (for example, different key names), the dispatcher must be updated to conform.
- **Connection (SPEC-3):** Add `:telemetry.execute/3` calls at three points: in `init/1` (`:connected`), in `terminate/2` (`:disconnected` with session duration computed from a start timestamp stored in GenServer state, and the count of pending commands from the Connection's own tracking), and at the point in the connection lifecycle where a new WebSocket replaces an existing one (`:replaced`). Remove the existing Logger.info calls that currently log connection and disconnection events — these are superseded by the telemetry events and the log handler. Keeping both would produce duplicate log lines for the same transitions. The `:replaced` event is emitted by whichever module manages the machine-to-connection mapping (the Agent registry or equivalent from SPEC-3) immediately before the old connection process is stopped. Note that this means the `:replaced` event may not originate from the Connection GenServer itself but from the registry module — the Event Contract table groups it under "Agent Connection Events" because it pertains to agent connections, not because it is emitted from the Connection module. The start timestamp must be captured using `:erlang.monotonic_time/0` (not `System.system_time/0`) so that the duration calculation is immune to system clock adjustments. The `system_time` measurement for `:connected` and `:replaced` events should use `System.system_time/0` since it represents a wall-clock timestamp, not a duration basis.
- **Router:** Add a module Plug (not a function plug — it needs its own module for clarity and testability) that stores the start time in `conn.private`, registers a `before_send` callback, and in that callback emits the HTTP request stop event with duration, method, route pattern, and status. This Plug should be placed early in the pipeline, before routing, so that it captures the full request lifecycle including any time spent in authentication or other plugs. The start time stored in `conn.private` should use `:erlang.monotonic_time/0` for the same clock-adjustment reason as above.

### Coordination with SPEC-6 (Audit)

Both this spec and SPEC-6 attach telemetry handlers to the dispatcher events. Each handler must use a distinct handler ID so they can be attached and detached independently. The handlers have no ordering dependency — telemetry handlers are called in attachment order but each should be self-contained and not depend on side effects of the other.

If SPEC-6 has not yet been implemented when this spec is built, the coordination requirement still applies: the handler ID chosen here must be documented (or defined as a module attribute) so that SPEC-6 can avoid colliding with it.

## Task Breakdown

The following tasks are listed in dependency order. Tasks within the same group have no dependencies on each other and can be worked in parallel.

### Group 1: Foundation (no internal dependencies)

**Task 1A — Dependencies and config.** Add `telemetry_metrics` and `logger_json` to `mix.exs`. Configure the JSON formatter for prod in `runtime.exs` and explicitly set the default formatter for test in `config/test.exs`. Verify `mix deps.get` succeeds without version conflicts.

**Task 1B — Telemetry handler module.** Create `ExCodeRemote.Telemetry` with `attach/0` (using `attach_many/4`), the handler callback with rescue wrapper, metadata scrubbing, string truncation, duration conversion, startup confirmation log line, and structured log output. This module can be built and unit-tested in isolation using manually executed telemetry events — it does not require the Connection or Router changes to exist.

**Task 1C — Metrics definitions module.** Create `ExCodeRemote.Telemetry.Metrics` with the `metrics/0` function returning the full list of metric structs. This is a pure data module with no runtime dependencies and can be built and tested independently.

### Group 2: Event emission (depends on Group 1 for the contract, but can be built in parallel with each other)

**Task 2A — Connection telemetry events.** Modify the Connection GenServer to emit `:connected`, `:disconnected`, and `:replaced` events. Store the monotonic start timestamp in GenServer state. Normalize the disconnect reason to a fixed atom set. Remove the existing Logger.info calls that are superseded by these telemetry events.

**Task 2B — HTTP timing Plug.** Create the module Plug that captures request start time, registers the `before_send` callback, reads the matched route pattern, and emits the HTTP stop event.

### Group 3: Wiring (depends on Group 1 and Group 2)

**Task 3A — Application startup.** Call `ExCodeRemote.Telemetry.attach/0` in `Application.start/2`, before the endpoint and connection acceptor are started in the supervision tree.

**Task 3B — Router integration.** Add the HTTP timing Plug to the router pipeline, before routing.

### Group 4: Validation (depends on all above)

**Task 4A — Integration tests.** Write the tests listed in the Tests section below. These require the full stack to be wired up.

**Task 4B — Manual validation.** Verify dev and prod log output as described in the Validation section.

## How to Evaluate

### Success Criteria

- [ ] Every event in the contract above is emitted by its owning module with the exact event name, measurement keys, and metadata keys specified
- [ ] `ExCodeRemote.Telemetry.attach/0` is called in `Application.start/2` and produces a log line for each emitted event
- [ ] A startup log line confirms the telemetry handler was attached successfully, including the count of events subscribed — this line must be visible in deploy logs during the SPEC-8 bake-off
- [ ] Prod logs are valid JSON — every line parses successfully, not just the first one (verify with a multi-event sequence piped through `jq`)
- [ ] Dev logs remain human-readable and are not JSON-formatted
- [ ] `ExCodeRemote.Telemetry.Metrics.metrics/0` returns a flat list of `Telemetry.Metrics` structs
- [ ] No sensitive fields (file contents, auth tokens) appear in log output
- [ ] Dispatcher round-trip latency (p99 over 1000 sequential dispatches to a connected agent) remains under 10ms with telemetry attached — this is validated manually, not as an automated test
- [ ] The telemetry handler survives a metadata encoding error without being detached — verify that events continue to be logged after one event triggers the rescue path
- [ ] The `before_send` callback correctly reads the route pattern after routing has completed, producing the matched pattern for known routes and `"unmatched"` for 404s
- [ ] Duration values in log output are in milliseconds (not native time units)
- [ ] The handler ID used by this spec does not collide with the SPEC-6 audit handler ID
- [ ] The existing Logger.info calls in the SPEC-3 Connection module for connect/disconnect are removed — no duplicate log lines for the same lifecycle event
- [ ] Each event type is logged at the correct level as specified in the Log levels section
- [ ] An operator can reconstruct the full lifecycle of a failed command — from dispatch, through agent disconnect, to timeout — using only the structured log output, without access to source code or additional debugging tools
- [ ] The telemetry output is sufficient to answer the three bake-off monitoring questions from SPEC-8: how often are agents disconnecting (and are commands orphaned when they do), what is the command latency distribution, and what is the error rate by type

### Tests

Tests should be included with the implementation changes:

- **Telemetry event capture**: attach a test handler, dispatch a command through a fake agent, assert `:start` and `:stop` events received with expected metadata keys and types (`machine` is a string, `command_id` is a string, `type` is an atom, `status` is an atom, `duration` is a positive integer).
- **Connection events**: connect/disconnect a fake agent, assert `:connected` and `:disconnected` events received with the machine name. Verify that `:disconnected` includes `duration` as a positive integer, `pending_count` as a non-negative integer, and `reason` as an atom.
- **Replaced event**: simulate a reconnect that supplants an existing connection, assert the `:replaced` event fires with the machine name and `old_pid` as a PID. Also verify that the corresponding `:disconnected` event for the old connection has `reason` set to `:replaced`.
- **HTTP event**: make a request to `/health`, assert the HTTP stop event fires with `status: 200`, `method: "GET"`, and that `route` is the matched pattern, not the literal path. This test assumes a `/health` endpoint exists — if it does not exist in the current codebase, use any defined route instead.
- **HTTP 404 route tag**: make a request to a nonexistent path, assert the HTTP stop event fires with `route` set to `"unmatched"`, not the raw path.
- **Metadata scrubbing**: emit a telemetry event whose metadata includes `content` and `auth_token` fields, capture the log output, and assert those fields do not appear in the logged JSON.
- **Large value truncation**: emit a telemetry event with a metadata field containing a 10KB string, capture the log output, and assert the field value is at most 200 bytes. Additionally, emit an event with a metadata string that contains a multi-byte UTF-8 character straddling the 200-byte boundary, and assert the output is valid UTF-8 (not truncated mid-character).
- **Handler crash resilience**: attach the handler, emit an event whose metadata contains a value that would cause the handler to raise (such as a non-encodable term like a reference or port), then emit a normal event and assert it is still logged. Also assert that an error-level log line was produced for the failed event.
- **Metrics module**: `Metrics.metrics/0` returns the expected number of metric specs, each one is a valid `Telemetry.Metrics` struct, and no metric uses `old_pid` as a tag.
- **Scrub list completeness**: assert that the scrub list module attribute contains at least `content` and `auth_token`. This is a guard rail so that future changes to the scrub list are intentional.
- **Duration unit in metrics**: assert that every distribution metric in the `metrics/0` list declares an explicit `unit` option.
- **Log level correctness**: emit each category of telemetry event (dispatcher start, dispatcher stop, dispatcher exception, agent connected, agent disconnected, agent replaced, HTTP request stop), capture the log output, and assert that each event is logged at the level specified in the Log levels section (info, info, error, info, warning, info, info respectively).
- **Duration conversion in log output**: emit a dispatcher command stop event with a known duration value in native time units, capture the log output, and assert the logged duration is the correctly converted millisecond value.
- **Stacktrace formatting**: emit a dispatcher command exception event with a raw stacktrace in the metadata, capture the log output, and assert the stacktrace field in the logged JSON is a human-readable string (not a raw tuple list).

### Validation

- `mix test` passes
- Manual: run `mix run --no-halt` in dev, tail the logs, dispatch a few commands, confirm both human-readable (dev) and JSON (prod via `MIX_ENV=prod`) output look sensible
- Manual: in prod mode, pipe log output through `jq .` and confirm every line parses without error
- Manual: verify that connecting and disconnecting an agent produces the expected `:connected` and `:disconnected` log lines with correct fields
- Manual: verify that the old Logger.info connection/disconnection messages no longer appear — only the telemetry handler log lines should be present
- Manual: verify that the startup confirmation log line appears on boot, confirming the handler is attached and listing the event count
- Manual: run the p99 latency benchmark described in the success criteria (1000 sequential dispatches to a connected agent, confirm p99 stays under 10ms with telemetry attached)
- Manual: simulate the bake-off diagnostic workflow — connect an agent, dispatch several commands (including one that times out), disconnect the agent, then review the JSON log output and confirm you can answer: how many commands succeeded, what was the latency of each, why did the agent disconnect, and how many commands were orphaned

## Risks

- **Silent handler detachment.** The `:telemetry` library detaches any handler that raises. If not mitigated with a rescue wrapper (described above), a single bad event silently kills all observability. This is the highest-risk item in the spec.
- **Metric cardinality.** If the HTTP `route` tag uses the raw request path instead of the matched route pattern, any downstream reporter (SPEC-8) will produce an unbounded number of time series. The contract above requires the route pattern specifically to prevent this. Similarly, the `old_pid` field must never be used as a metric tag.
- **Log formatter interaction with tests.** If the JSON formatter is active during test runs, `ExUnit.CaptureLog` will capture JSON instead of plain text, breaking string-match assertions. The test environment must explicitly use the default formatter.
- **Route pattern availability in before_send.** The timing Plug relies on `conn.private[:plug_route]` being populated by the time the `before_send` callback fires. If the router implementation in this project stores the matched route under a different key, the Plug will silently emit `"unmatched"` for every request. During implementation, verify the actual key name by inspecting `conn.private` after a matched request. The HTTP event test (making a request to a known route and asserting the route pattern is present) serves as an automated guard against this.
- **before_send may not fire on process crashes.** If the request process terminates abnormally (for example, an unhandled exception that crashes the process before the response is sent), the `before_send` callback may not execute and the request will produce no HTTP telemetry event. This is an accepted gap — such crashes should be rare and would be visible through other means (server error logs, supervision tree restarts). Distributed tracing (out of scope) would be needed to fully close this gap.
- **Clock source for durations.** Using `System.system_time/0` instead of `:erlang.monotonic_time/0` for duration calculations would produce incorrect values if the system clock is adjusted (for example, by NTP). The spec requires monotonic time for all duration measurements.
- **Dependency version conflicts.** Adding an explicit `telemetry ~> 1.2` constraint could conflict with the version range required by Bandit or ThousandIsland. Verify compatibility before merging.
- **Log volume at high throughput.** Every dispatched command produces at least two log lines (start and stop) and every HTTP request produces one. In high-throughput deployments this could generate substantial log volume. This spec does not add sampling or rate limiting — operators can manage volume by adjusting the Elixir Logger level. If this proves insufficient in practice, a future spec could add a configurable log level per event category, but that complexity is not warranted now.

## Notes

- The event list is the **contract**. Changes to metadata keys or event names require a spec update because downstream dashboards will depend on them.
- Duration is emitted in native time units everywhere and each consumer converts. Native time units are the BEAM's internal time representation, which varies by platform — the telemetry library emits durations in this unit by default. The log handler converts to ms for readability; metrics specs declare the conversion explicitly via the `unit` option on each duration metric.
- We deliberately do not start a reporter (Prometheus, StatsD, OpenTelemetry) in this spec. That's a deployment decision; this spec hands SPEC-8 the raw material to plug one in. SPEC-8 should call `ExCodeRemote.Telemetry.Metrics.metrics/0` and pass the returned list to whatever reporter it configures.
- The Metrics module delivers no runtime value during the initial bake-off. SPEC-8 defers reporter wiring entirely — Fly's built-in log aggregation is the sole consumer of this work for the initial deployment. The Metrics module is included now because it is cheap (pure data, no runtime cost) and reduces the integration cost when monitoring is eventually wired. It is an investment in future operational capability, not an immediate operational tool. The structured JSON logs are the tool that matters for the bake-off.
- The scrub list (`content`, `auth_token`) is the initial set. As new sensitive fields are added to metadata in future specs, the scrub list must be updated here as well.

## Observations

- [decision] Telemetry events are the contract, log lines are one consumer — lets us add dashboards/metrics later without touching business logic
- [decision] JSON logs in prod, human-readable in dev — standard split, makes local debugging pleasant and prod logs machine-readable
- [decision] No reporter in this spec — reporter choice depends on deploy environment, defer to SPEC-8
- [decision] Scrub `content` and `auth_token` from metadata — logs should not contain blobs or secrets
- [decision] Telemetry.Metrics definitions co-located with the events — single source of truth for what the service measures
- [decision] Dispatcher events already exist from SPEC-4; this spec formalizes the contract and adds agent/HTTP events
- [decision] HTTP route tag uses matched pattern, not raw path — prevents cardinality explosion in downstream metrics
- [decision] Handler wraps body in rescue to survive errors — prevents silent detachment, which is the default telemetry behavior
- [decision] Monotonic time for duration calculations, system time for wall-clock timestamps — immune to NTP adjustments
- [decision] Existing SPEC-3 Logger.info calls for connection lifecycle are removed, not kept alongside telemetry — avoids duplicate log output
- [decision] HTTP events have no :start event and agent events have no :exception event — these asymmetries are intentional and reflect the different nature of each event category
- [decision] The :replaced event may be emitted from the registry module rather than the Connection GenServer, since it is the registry that manages the machine-to-connection mapping
- [decision] Observability is the evidentiary mechanism for the port's go/no-go decision — this work directly enables the SPEC-8 bake-off verdict
- [decision] Startup confirmation log line is required — gives operators an immediate signal that observability is live after each deploy
- [pattern] Telemetry span for the dispatcher hot path — idiomatic, correctly propagates exceptions as `:exception` events
- [pattern] attach_many for a single handler covering all events — simpler management than one handler per event
- [anti-pattern] Hand-rolled event-loop stall watchdog — not needed on BEAM, removed structurally
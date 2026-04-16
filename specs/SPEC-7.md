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

Rather than hand-rolled log lines, this spec defines a **telemetry event contract** that downstream consumers (logs, metrics, dashboards) can subscribe to. The dispatcher and connection processes emit events; a telemetry handler converts them to structured logs now, and gives us a clean seam to add metrics reporters later without touching business logic.

## What

**In scope:**

- A documented list of telemetry events emitted across the codebase
- `ExCodeRemote.Telemetry` module that attaches a handler and emits structured log lines (JSON) for each event
- Logger configuration for JSON formatting in production, human-readable in dev
- A minimal `ExCodeRemote.Telemetry.Metrics` module that defines Telemetry.Metrics specs for the events — not wired to a reporter yet, but documented so SPEC-8 (deployment) can plug in a reporter of choice

**Out of scope:**

- LiveDashboard (nice-to-have, but drags in Phoenix LiveView for a headless service)
- Prometheus / StatsD / OpenTelemetry reporters — the events and metrics definitions land here, the reporter choice lands in SPEC-8 or later
- Distributed tracing
- Custom log backends

## Event Contract

All events are under the `[:ex_code_remote, …]` namespace.

### Dispatcher Events (emitted in SPEC-4)

| event | measurement | metadata |
|---|---|---|
| `[:ex_code_remote, :dispatcher, :command, :start]` | `system_time` | `machine`, `command_id`, `type` |
| `[:ex_code_remote, :dispatcher, :command, :stop]` | `duration` (native time units) | `machine`, `command_id`, `type`, `status` |
| `[:ex_code_remote, :dispatcher, :command, :exception]` | `duration` | `machine`, `command_id`, `type`, `kind`, `reason`, `stacktrace` |

### Agent Connection Events (emitted in SPEC-3, additions here)

| event | measurement | metadata |
|---|---|---|
| `[:ex_code_remote, :agent, :connected]` | `system_time` | `machine` |
| `[:ex_code_remote, :agent, :disconnected]` | `duration` (session length, native) | `machine`, `reason`, `pending_count` |
| `[:ex_code_remote, :agent, :replaced]` | `system_time` | `machine` (emitted when a reconnect supplants a previous connection) |

### HTTP Events (emitted in router, additions here)

| event | measurement | metadata |
|---|---|---|
| `[:ex_code_remote, :http, :request, :stop]` | `duration` | `method`, `path`, `status` |

## How (High Level)

### Telemetry Handler

`ExCodeRemote.Telemetry` attaches to all events listed above at application start. Each event is logged as a structured JSON object containing the event name, measurements (with duration converted to milliseconds), and metadata.

Sensitive fields (`content`, `auth_token`) are dropped from metadata before logging. Oversized string values are truncated to 200 bytes.

### Logger Config

In production, use a JSON log formatter (such as `logger_json`) so logs can be piped into `jq` or ingested by a log aggregator. In dev, keep the default human-readable formatter. This split is configured in `runtime.exs`.

### Metrics Definitions

`ExCodeRemote.Telemetry.Metrics` defines Telemetry.Metrics specs for the events above: counters for commands dispatched (tagged by machine, type, and status), distributions for command duration, counters for agent connections/disconnections (tagged by machine and reason), and counters/distributions for HTTP requests (tagged by method and status).

These are **definitions only** in this spec — no reporter is started. SPEC-8 can pick a reporter when deploying.

### Dependencies

Add Telemetry (`~> 1.2`), Telemetry.Metrics (`~> 1.0`), and a JSON log formatter (such as `logger_json ~> 6.0`) to deps.

### Adding Events to Existing Code

This spec revisits the dispatcher (SPEC-4) and connection (SPEC-3) to emit the events above. The changes are mechanical:

- Dispatcher: wrap `run/2` in a telemetry span.
- Connection: emit telemetry events on register and terminate.
- Router: a small Plug that times each request and emits an event via `before_send`.

## How to Evaluate

### Success Criteria

- [ ] Every event in the contract above is emitted by its owning module
- [ ] `ExCodeRemote.Telemetry.attach/0` is called at application start and produces a log line for each emitted event
- [ ] Prod logs are valid JSON (can be piped into `jq`)
- [ ] `ExCodeRemote.Telemetry.Metrics.metrics/0` returns a list of Telemetry.Metrics specs
- [ ] No sensitive fields (file contents, auth tokens) appear in log output
- [ ] Dispatcher round-trip latency remains under 10ms with telemetry attached

### Tests

Tests should be included with the implementation changes:

- **Telemetry event capture**: attach a test handler, dispatch a command through FakeAgent, assert `:start` and `:stop` events received with expected metadata.
- **Connection events**: connect/disconnect a FakeAgent, assert `:connected` and `:disconnected` events received with the machine name.
- **HTTP event**: make a request to `/health`, assert the HTTP stop event fires with `status: 200`.
- **Metadata scrubbing**: assert that a telemetry event containing `content` or `auth_token` in its metadata has those fields dropped in the log output.
- **Large value truncation**: a metadata field with a 10KB string is truncated to 200 bytes in the log output.
- **Metrics module**: `Metrics.metrics/0` returns the expected number of metric specs and each one compiles without errors.

### Validation

- `mix test` passes
- Manual: run `mix run --no-halt` in dev, tail the logs, dispatch a few commands, confirm both human-readable (dev) and JSON (prod via `MIX_ENV=prod`) output look sensible

## Notes

- The event list is the **contract**. Changes to metadata keys or event names require a spec update because downstream dashboards will depend on them.
- Duration is emitted in native time units everywhere and each consumer converts. The log handler converts to ms for readability; metrics specs declare the conversion explicitly.
- We deliberately do not start a reporter (Prometheus, StatsD, OpenTelemetry) in this spec. That's a deployment decision; this spec hands SPEC-8 the raw material to plug one in.

## Observations

- [decision] Telemetry events are the contract, log lines are one consumer — lets us add dashboards/metrics later without touching business logic
- [decision] JSON logs in prod, human-readable in dev — standard split, makes local debugging pleasant and prod logs machine-readable
- [decision] No reporter in this spec — reporter choice depends on deploy environment, defer to SPEC-8
- [decision] Scrub `content` and `auth_token` from metadata — audit log should not contain blobs, logs should not contain secrets
- [decision] Telemetry.Metrics definitions co-located with the events — single source of truth for what the service measures
- [pattern] Telemetry span for the dispatcher hot path — idiomatic, correctly propagates exceptions as `:exception` events
- [anti-pattern] Hand-rolled event-loop stall watchdog — not needed on BEAM, removed structurally

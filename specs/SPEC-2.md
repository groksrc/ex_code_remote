---
title: 'SPEC-2: HTTP Skeleton'
type: spec
permalink: specs/spec-2-http-skeleton
tags:
- skeleton
- plug
- bandit
- health
---

# SPEC-2: HTTP Skeleton

Status: Implemented

## Why

Every later spec hangs off an HTTP server: the MCP tools surface as a mounted Plug, the agent WebSocket is a route upgrade, and the audit/debug endpoints are plain routes. Before any of that, we need a **walking skeleton** — a deployable, compiling Elixir application whose top-level supervisor starts Bandit, serves a single `/health` endpoint, and does nothing else.

The value of shipping a skeleton PR first is that every subsequent spec has a concrete place to plug in. It also makes deployment (SPEC-8) a boring diff instead of a first-time exercise under pressure.

Beyond unblocking engineering, this skeleton establishes the operational surface area for the product. The `/health` endpoint is the first thing an operator or deployment pipeline will interact with. Getting this right early means that integration testing, staging environments, and CI pipelines can begin exercising the real system immediately — not mocks or stubs. Every spec that follows ships into an environment that already knows how to build, start, and health-check the application.

Bandit is chosen over Cowboy because it provides native WebSocket upgrade support that SPEC-3 will rely on, and it is a pure-Elixir HTTP server that aligns with the no-Phoenix posture established in SPEC-1.

## What

The initial Mix scaffold with:

- `ExCodeRemote.Application` supervisor tree starting Bandit
- `ExCodeRemote.Router` — a `Plug.Router` with one live route (`/health`) and a catch-all 404
- Runtime config via `config/runtime.exs` for `PORT` (default `4000`)
- Enough structure in `lib/ex_code_remote/` to match the directory layout from SPEC-1, even if most directories are empty stubs

**Explicitly out of scope for this spec:**

- MCP routes (SPEC-5)
- WebSocket upgrade at `/ws/agent` (SPEC-3)
- Audit or `/commands` endpoints (SPEC-6)
- Any persistence layer
- Any authentication
- TLS termination (expected to be handled by a reverse proxy in front of Bandit)

## Prerequisites

This spec assumes the Mix project created in SPEC-1 already exists, including `mix.exs` with the `application/0` and `project/0` functions. If SPEC-1 has not been implemented, the implementer must first create the Mix project with `mix new ex_code_remote --sup` (or equivalent) before proceeding.

The implementer should confirm that the version string in the `project/0` function of `mix.exs` is set (e.g. `"0.1.0"`), since the health endpoint will surface this value. Any valid semver string is acceptable — the exact value is not prescribed by this spec.

## How (High Level)

### Dependencies

Initial `mix.exs` deps: Bandit (`~> 1.10`), Plug (`~> 1.17`), Jason (`~> 1.4`). ExMCP is deferred to SPEC-5. Req is added as a test-only dependency (with `only: :test, runtime: false`) for the integration test that hits the live HTTP server.

ThousandIsland is a transitive dependency pulled in by Bandit — it should not be added as a direct dependency. The integration test will call into ThousandIsland's API to retrieve the bound port, and this is fine as a transitive usage.

### Application Callback

The `mix.exs` `application/0` function must declare `mod: {ExCodeRemote.Application, []}` so that the OTP application starts the supervision tree on boot. If SPEC-1 already set this up, confirm it points to the correct module; if not, add it.

### Supervisor Tree

The `Application` module starts a single Bandit child spec bound to the configured port, serving `ExCodeRemote.Router`. The Bandit child is started with `scheme: :http` explicitly — no TLS at the application level. This child sits directly under the top-level supervisor; later specs (SPEC-3, SPEC-4) will add sibling children such as a DynamicSupervisor and Registry to the same supervisor.

The Bandit child spec must include a name option so that the running Bandit server process can be referenced by other parts of the system. This is necessary for the integration test (which needs to retrieve the actual bound port when started on port zero) and will also be useful for later specs that need to introspect server state. Use the module name `ExCodeRemote.Bandit` as the registered name.

The supervisor strategy should be `one_for_one`. If Bandit crashes, only the HTTP listener restarts — future sibling processes are unaffected.

### Router

The router module should live at `lib/ex_code_remote/router.ex`, consistent with standard Mix project conventions.

A `Plug.Router` with `:match` and `:dispatch` plugs. No `Plug.Parsers` is needed in this spec since no routes accept a request body.

The `/health` route returns a 200 response with `content-type: application/json`. The JSON body contains three fields: `status` (the string `"ok"`), `version` (the application version string read from the app spec via `Application.spec(:ex_code_remote, :vsn)`), and `timestamp` (current UTC time as an ISO8601 string with a `Z` suffix, e.g. `"2026-04-15T12:00:00Z"`). The response body is encoded using `Jason.encode!`.

**Important implementation detail on the version field:** `Application.spec(:ex_code_remote, :vsn)` returns a charlist (single-quoted Erlang string), not an Elixir binary string. This must be converted to a binary string (via `to_string/1` or `List.to_string/1`) before passing it to Jason, otherwise Jason will encode it as a JSON array of integers rather than a string. If the application has not been loaded yet (for example, during certain test scenarios), `Application.spec/2` may return `nil` — handle this by falling back to `"unknown"` or loading the app first.

**Important implementation detail on the timestamp field:** `DateTime.utc_now/0` followed by `DateTime.to_iso8601/1` produces a string that includes microsecond precision (e.g. `"2026-04-15T12:00:00.000000Z"`). This is acceptable — the success criteria require a valid ISO8601 UTC string, and microsecond precision satisfies that. The example format in this spec (`"2026-04-15T12:00:00Z"`) is illustrative, not prescriptive about precision. If truncation to whole seconds is preferred, use `DateTime.truncate(datetime, :second)` before converting to ISO8601.

All unmatched routes return a 404 response with `content-type: application/json` and a body of `{"error": "not found"}`. This gives downstream consumers a consistent JSON contract from the start rather than requiring them to handle mixed content types.

The router is the primary extension point for later specs. SPEC-5 will mount the MCP plug via `forward`, and SPEC-6 will add command routes. The router should be structured so that adding a `forward "/mcp", to: SomePlug` or a new `get "/commands"` block is a clean, small diff.

### Runtime Config

All configuration lives in `config/runtime.exs` — no `config/config.exs`. The `PORT` env var is read as a string and converted to an integer via `String.to_integer/1`. If `PORT` is not set, the default is `4000`. No validation of the port value beyond the integer conversion is needed — Bandit will raise clearly if the port is unusable (e.g. already bound, privileged range without permissions). This gives dev and prod the same config load path.

Note that `String.to_integer/1` will raise an `ArgumentError` for any non-numeric string, including an empty string. This is the desired behavior — a misconfigured `PORT` should crash loudly at startup rather than silently falling back to a default.

The port value should be stored under `config :ex_code_remote, :port` so it can be read cleanly from the Application module at startup.

### Logging

Bandit logs startup and request information through Elixir's Logger by default. No custom log configuration is needed in this spec. The startup log line that the success criteria reference is produced by Bandit itself when it begins listening — confirm it appears and includes the bound port.

### Directory Stubs

Create the directory structure from SPEC-1 so later PRs have a place to land files: `mcp/`, `agent/`, and `commands/` under `lib/ex_code_remote/`, with `.gitkeep` files. If SPEC-1 defines additional directories beyond these three, those should also be created. The implementer should cross-reference SPEC-1's directory layout section and create stubs for any directories listed there.

## How to Evaluate

### Success Criteria

- [ ] `mix compile --warnings-as-errors` succeeds
- [ ] `mix run --no-halt` starts Bandit on the configured port and logs a startup line that includes the port number
- [ ] `GET /health` returns `200` with a `content-type` header whose value starts with `application/json` (Plug may append a charset parameter such as `; charset=utf-8`, which is acceptable) and a JSON body containing `status`, `version`, and `timestamp`
- [ ] The `status` field is the string `"ok"`
- [ ] The `version` field is a string (not a JSON array of integers), matching the version declared in `mix.exs`
- [ ] The `timestamp` field in the health response is a valid ISO8601 UTC string ending in `Z`
- [ ] `GET /does-not-exist` returns `404` with a `content-type` header whose value starts with `application/json` and a JSON error body containing `{"error": "not found"}`
- [ ] `PORT=4321 mix run --no-halt` binds to `4321`
- [ ] Setting `PORT` to a non-integer value (including an empty string) causes a clear crash at startup (not a silent default)
- [ ] Directory stubs for `mcp/`, `agent/`, `commands/` exist under `lib/ex_code_remote/`
- [ ] The Bandit child spec in the supervisor includes a registered name so the process is addressable
- [ ] The router can be extended with a new route or a `forward` to a sub-plug without modifying existing route definitions — this is the primary value this skeleton delivers to the rest of the spec chain

### Tests

Tests should be included with the implementation changes:

- A `Plug.Test`-based unit test for `ExCodeRemote.Router` asserting:
  - `GET /health` returns status 200 with a `content-type` header whose value starts with `application/json`
  - The decoded JSON body contains exactly the keys `status`, `version`, and `timestamp`
  - The `status` value is `"ok"`
  - The `version` value is a binary string (not nil, not a list)
  - The `timestamp` value is a valid ISO8601 string (parseable by `DateTime.from_iso8601/1` without error)
  - An unknown route (e.g. `GET /nope`) returns status 404 with a `content-type` header whose value starts with `application/json` and a decoded body containing `"error" => "not found"`
  - A non-GET method to an unknown route (e.g. `POST /nope`) also returns 404 with the same JSON structure, confirming the catch-all is method-agnostic

- An integration test that starts Bandit on an ephemeral port (by configuring port `0`, which causes the OS to assign an available port), retrieves the actual bound port from Bandit, hits `/health` via Req, and asserts a 200 response with the expected JSON structure. This test proves the full stack — supervisor, Bandit, router — wires up correctly, not just the Plug pipeline in isolation.

  **Port usage in tests:** No test should hardcode a specific port number. All tests that start a listener must use port `0` to let the OS assign an ephemeral port. This prevents conflicts when tests run in parallel or in CI environments where ports may already be in use.

  **Retrieving the bound port:** After starting the application (or the Bandit child directly), the actual port can be obtained by calling `ThousandIsland.listener_info/1` on the named Bandit server process. This returns a map containing the bound address and port. The test should use the registered process name established in the supervisor child spec to locate the server. If using `start_supervised` in the test rather than booting the full application, pass the same Bandit child spec with port `0` and the registered name.

  **Test cleanup:** If the integration test starts the Bandit process via `start_supervised`, ExUnit handles cleanup automatically when the test exits. If the test starts the full application supervisor, it must be stopped in an `on_exit` callback to avoid leaking the listener process into subsequent tests.

### Validation

- `mix test` passes with zero failures
- `mix compile --warnings-as-errors` zero warnings
- Manual smoke: `mix run --no-halt` in one terminal, `curl localhost:4000/health` in another — confirm the response is valid JSON with all three fields and that the `version` field is a quoted string, not a list of numbers

## Notes

- This PR is intentionally tiny. The point is to have a place for everything else to land.
- No `config/config.exs` is created. All config goes through `runtime.exs` so dev and prod have the same load path.
- The `/health` endpoint defined here is intentionally simple. SPEC-7 may evolve it into separate readiness and liveness probes once there are real subsystems to report on. The contract established here (200 with JSON containing `status`) should be treated as stable — SPEC-7 should extend it, not replace it.
- The health endpoint contract — JSON with a `status` field returning 200 — is a commitment to external consumers. Any CI pipeline, load balancer, or orchestrator that integrates against this endpoint should be able to rely on it indefinitely. SPEC-7's evolution must be additive, not breaking.

## Observations

- [decision] Single `/health` endpoint on the skeleton — no readiness/liveness split yet; can be added in SPEC-7 once we have something real to report on
- [decision] `Plug.Router` with inline routes rather than Phoenix Router — keeps the no-Phoenix posture from SPEC-1 intact
- [decision] `runtime.exs` only, no `config/config.exs` — one config path for every environment
- [decision] All responses are JSON, including errors — establishes a uniform contract that later specs and API consumers can rely on
- [decision] Bandit child is registered with a name — enables port introspection for tests and future operational tooling
- [pattern] Top-level `Application` starts exactly one Bandit child; future supervisors (DynamicSupervisor, Registry) get added as siblings in later specs
- [pattern] Router is the integration seam — later specs extend behavior by adding routes or forwarding to sub-plugs, not by replacing the router
- [gotcha] `Application.spec/2` returns a charlist for `:vsn` — must convert to binary string before JSON encoding or the version field will be an array of integers
- [gotcha] Plug's `put_resp_content_type` sets `application/json; charset=utf-8` by default, not bare `application/json` — tests and success criteria should match on prefix, not exact string
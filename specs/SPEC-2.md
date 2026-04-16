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

## Why

Every later spec hangs off an HTTP server: the MCP tools surface as a mounted Plug, the agent WebSocket is a route upgrade, and the audit/debug endpoints are plain routes. Before any of that, we need a **walking skeleton** — a deployable, compiling Elixir application whose top-level supervisor starts Bandit, serves a single `/health` endpoint, and does nothing else.

The value of shipping a skeleton PR first is that every subsequent spec has a concrete place to plug in. It also makes deployment (SPEC-8) a boring diff instead of a first-time exercise under pressure.

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

## How (High Level)

### Dependencies

Initial `mix.exs` deps: Bandit (`~> 1.10`), Plug (`~> 1.17`), Jason (`~> 1.4`). ExMCP is deferred to SPEC-5. A test-only HTTP client like Req for integration tests.

### Supervisor Tree

The `Application` module starts a single Bandit child spec bound to the configured port, serving `ExCodeRemote.Router`.

### Router

A `Plug.Router` with `:match` and `:dispatch` plugs. The `/health` route returns a 200 JSON response with fields: `status` ("ok"), `version` (from the app spec), and `timestamp` (current UTC ISO8601). All unmatched routes return 404.

### Runtime Config

All configuration lives in `config/runtime.exs` — no `config/config.exs`. The `PORT` env var defaults to `4000`. This gives dev and prod the same config load path.

### Directory Stubs

Create the directory structure from SPEC-1 so later PRs have a place to land files: `mcp/`, `agent/`, and `commands/` under `lib/ex_code_remote/`, with `.gitkeep` files.

## How to Evaluate

### Success Criteria

- [ ] `mix compile --warnings-as-errors` succeeds
- [ ] `mix run --no-halt` starts Bandit on the configured port and logs a startup line
- [ ] `GET /health` returns `200` with JSON body containing `status`, `version`, and `timestamp`
- [ ] `GET /does-not-exist` returns `404`
- [ ] `PORT=4321 mix run --no-halt` binds to `4321`
- [ ] Directory stubs for `mcp/`, `agent/`, `commands/` exist

### Tests

Tests should be included with the implementation changes:

- A `Plug.Test`-based unit test asserting `/health` returns 200 with the expected JSON fields and that an unknown route returns 404.
- An integration test that starts Bandit on an ephemeral (OS-assigned) port, hits `/health` via an HTTP client, and asserts a 200 response.

### Validation

- `mix test` passes with zero failures
- `mix compile --warnings-as-errors` zero warnings
- Manual smoke: `mix run --no-halt` in one terminal, `curl localhost:4000/health` in another

## Notes

- This PR is intentionally tiny. The point is to have a place for everything else to land.
- No `config/config.exs` is created. All config goes through `runtime.exs` so dev and prod have the same load path.

## Observations

- [decision] Single `/health` endpoint on the skeleton — no readiness/liveness split yet; can be added in SPEC-7 once we have something real to report on
- [decision] `Plug.Router` with inline routes rather than Phoenix Router — keeps the no-Phoenix posture from SPEC-1 intact
- [decision] `runtime.exs` only, no `config/config.exs` — one config path for every environment
- [pattern] Top-level `Application` starts exactly one Bandit child; future supervisors (DynamicSupervisor, Registry) get added as siblings in later specs

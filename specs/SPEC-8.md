---
title: 'SPEC-8: Deployment'
type: spec
permalink: specs/spec-8-deployment
tags:
- deployment
- fly
- docker
- release
- cutover
---

# SPEC-8: Deployment

## Why

After SPEC-7 the server is functionally complete: it has an HTTP surface, an MCP tool set, supervised agent connections, in-memory command correlation, a write-only audit log, and a telemetry event contract. This spec makes it deployable — an Elixir release, a Dockerfile, a Fly.io app definition, runtime config wired to secrets, and a cutover plan that lets the existing Python agent reconnect to the new server with a single env-var change.

The goal is to get the new server running *alongside* the Python server for a stability bake-off, not to replace it in one shot.

## What

**In scope:**

- Mix release configuration
- Multi-stage Dockerfile producing an OTP release image
- `fly.toml` with volume mount for the audit DB
- `config/runtime.exs` reading all prod config from env vars
- Secrets contract: `AUTH_TOKEN`, `DATABASE_PATH`, `PORT`
- Automated migration on release start via a release eval command
- Cutover plan for connecting the existing Python agent

**Out of scope:**

- Blue/green deployment automation (the cutover is manual: spin up new app, point agent at new URL, tear down old)
- Multi-region (single-region to match the Python version)
- Tailscale integration (SPEC-9)
- CI/CD pipeline (can be added later; initial deploy is manual `fly deploy`)
- Observability reporter wiring — events are emitted (SPEC-7) but not yet shipped to an external system; Fly's built-in log aggregation is enough for the bake-off

## How (High Level)

### Release Configuration

Configure `mix release` in `mix.exs` targeting Unix, including runtime_tools for remote debugging. A Release module provides a `migrate/0` function that loads the app, discovers Ecto repos, and runs all pending migrations. This is invoked via `bin/ex_code_remote eval` before the server starts.

### Dockerfile

A multi-stage build following the standard Elixir release pattern:

**Build stage:** Uses the official `hexpm/elixir` Alpine image. Installs build dependencies, copies mix files, fetches and compiles deps, copies source, compiles the release.

**Runtime stage:** Minimal Alpine image with only runtime dependencies (openssl, ncurses, libstdc++, libgcc). Copies the release from the build stage. Sets `PORT=8080` and `DATABASE_PATH=/data/audit.db` as defaults. The entry command runs migrations then starts the release.

### fly.toml

Key settings:

- **Region:** `dfw` (single region, matching the Python server)
- **Volume mount:** `ex_code_remote_data` at `/data` for the audit SQLite database
- **`auto_stop_machines = false`** — agents hold long-lived WebSocket connections; Fly's default auto-stop would sever every agent when the machine looks idle over HTTP
- **`min_machines_running = 1`** — always keep at least one instance up
- **Internal port:** 8080 with `force_https = true`

### Runtime Config

All production configuration reads from environment variables in `runtime.exs`: `PORT` (default 8080), `AUTH_TOKEN` (required, fails loudly if missing), `DATABASE_PATH` (default `/data/audit.db`), and the JSON log formatter for production.

### Secrets

`AUTH_TOKEN` is set via `fly secrets set` using 32 bytes of random hex. This is the same shared secret used for agent WebSocket auth and the `/commands` debug endpoint.

### Cutover Plan

The new server runs alongside the Python server at a different Fly app name. The Python agent switches over with a single env-var change. The plan:

1. **Deploy the new server** to Fly.io under a new app name. Create the volume, set the auth token secret (same as the Python server's), and deploy.
2. **Verify health** by hitting the new server's `/health` endpoint over HTTPS.
3. **Switch the agent** by updating `RELAY_URL` in the agent's `.env` to point at the new server's WebSocket URL. Restart the agent.
4. **Verify the connection** by checking logs for the agent connected message.
5. **Switch the MCP client** in Claude.ai connector settings to point at the new server's MCP endpoint.
6. **Bake for a week.** Monitor disconnect counts, command latency, and error rates in logs. Both servers stay up during this period; the Python server has no agent attached so it's idle.
7. **Retire the Python server** once the new one has proven stable.

### Rollback

If the new server misbehaves during the bake:

1. Revert `RELAY_URL` on the agent.
2. Revert the MCP connector URL.
3. Agent and MCP client reconnect to the Python server.
4. File bugs, fix, redeploy, try again.

Nothing in the new server is destructive to the Python server — they share no state.

## How to Evaluate

### Success Criteria

- [ ] `mix release` produces a working release locally
- [ ] `docker build .` succeeds and produces a runnable image
- [ ] The Docker image starts the server and `/health` responds when run locally
- [ ] `fly deploy` succeeds from a clean checkout
- [ ] Deployed app responds to `/health` over HTTPS
- [ ] Volume mounts correctly at `/data` and audit DB persists across restarts
- [ ] Migrations run on first start (verified in logs)
- [ ] Python agent successfully connects when pointed at the new `RELAY_URL`
- [ ] An MCP client can list tools and dispatch a `run_shell_command` against the connected agent
- [ ] Fly machine is not being auto-stopped (verified by checking uptime after 10+ minutes idle)

### Tests

Tests should be included with the implementation changes:

- **Release module test**: the `migrate/0` function runs successfully against a test Repo and is idempotent (second run is a no-op).
- **Dockerfile smoke test**: build the image and run it locally with a test auth token, hit `/health`, assert 200.

There is also a manual deploy validation checklist:

- `fly deploy` from clean checkout succeeds
- Logs show "migration ran" and server started
- `/health` returns 200 over HTTPS
- Python agent connects, `check_agent_status` via MCP shows the machine
- `run_shell_command` returns expected output
- After `fly machine restart`, agent reconnects and commands work again
- After 30 min idle, machine is still running (auto-stop disabled)

### Validation

- `mix test` passes (release module tests)
- Deploy validation checklist completed against the deployed app

## Notes

- Single-machine, single-region is a hard constraint of the current architecture (WebSocket state is in-process). Multi-region or clustering is a future spec that would require a distributed registry. Not worth doing until there's a second region worth running in.
- The `auto_stop_machines = false` setting is non-obvious but critical. Fly's default is to stop machines that look idle, but HTTP-wise the machine looks idle even while holding an active WebSocket.
- The cutover keeps the old server alive during the bake so rollback is instant. The Python server has no agent attached during the bake, so it costs basically nothing.
- `fly machine restart` is the rollout primitive once the app is live. For code changes, `fly deploy` does a rolling replace that will briefly drop the agent connection; the agent's built-in reconnect handles it.

## Observations

- [decision] Mix release + multi-stage Dockerfile + Fly.io — boring, proven, matches standard Elixir deployment
- [decision] Single-region, single-machine — matches current architecture, revisit when clustering is needed
- [decision] `auto_stop_machines = false` — agents hold long-lived connections, cannot survive auto-stop
- [decision] Cutover runs the new server alongside the old, switches agent via env var — instant rollback, zero data migration
- [decision] Migrations run on start via release eval command — no separate migration step, deploy is atomic
- [decision] Bake for a week before retiring the Python server — stability is the whole point of the port, prove it before committing
- [constraint] WebSocket state is in-process, so we cannot horizontally scale without a distributed registry
- [risk] `auto_stop_machines = false` must not regress — add a deploy check or doc warning

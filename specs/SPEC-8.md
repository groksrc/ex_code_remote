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

Status: Implemented

## Why

After SPEC-7 the server is functionally complete: it has an HTTP surface, an MCP tool set, supervised agent connections, in-memory command correlation, a write-only audit log, and a telemetry event contract. This spec makes it deployable — an Elixir release, a Dockerfile, a Fly.io app definition, runtime config wired to secrets, and a cutover plan that lets the existing Python agent reconnect to the new server with a single env-var change.

The goal is to get the new server running *alongside* the Python server for a stability bake-off, not to replace it in one shot.

The customer outcome this enables: the person operating the remote agent (and anyone accessing it via MCP) gets a server that is more reliable, more observable, and easier to extend than the Python original — but only after we've proven that claim in production under real workload. Until the bake period passes, the customer sees no change. After it passes, the customer gets a server that handles agent disconnects gracefully, logs structured telemetry, and provides a foundation for Tailscale-secured access (SPEC-9). This spec is the bridge between "code complete" and "customer value delivered."

## What

**Dependencies:** All prior specs (SPEC-1 through SPEC-7) must be complete.

**In scope:**

- Mix release configuration
- Release module with `migrate/0` function
- Multi-stage Dockerfile producing an OTP release image (must include SQLite native libraries for exqlite from SPEC-6)
- `.dockerignore` file
- Startup entrypoint script that chains migration and server boot
- `fly.toml` with volume mount for the audit DB
- `config/runtime.exs` reading all prod config from env vars
- Secrets contract: `AUTH_TOKEN`, `DATABASE_PATH`, `PORT`
- Automated migration on release start via a release eval command
- Cutover plan for connecting the existing Python agent
- Cutover plan for switching the MCP client endpoint

**Out of scope:**

- Blue/green deployment automation (the cutover is manual: spin up new app, point agent at new URL, tear down old)
- Multi-region (single-region to match the Python version)
- Tailscale integration (SPEC-9)
- CI/CD pipeline (can be added later; initial deploy is manual `fly deploy`)
- Observability reporter wiring — events are emitted (SPEC-7) but not yet shipped to an external system; Fly's built-in log aggregation is enough for the bake-off
- Migration of audit data from the Python server — the new server starts with a fresh audit database
- Backup strategy for the audit DB volume — acceptable for the bake period, should be addressed before the system is considered production-grade
- TLS certificate management — Fly handles TLS termination automatically for `.fly.dev` domains; no custom domain or certificate configuration is needed for the bake period

## How (High Level)

### Task Dependencies

The work in this spec decomposes into the following tasks. Dependencies are noted so implementers know what must land first.

- **Task A: Release configuration** (mix.exs changes and Release module) — no dependencies within this spec, depends on all prior specs being complete
- **Task B: Runtime config** (runtime.exs) — no dependencies within this spec, can be done in parallel with Task A
- **Task C: Dockerfile and .dockerignore** — depends on Task A (release must be configured before the Dockerfile can build it) and Task B (runtime config must be in place for the image to start correctly)
- **Task D: fly.toml** — depends on Task C (needs to reference the image and port)
- **Task E: Cutover plan documentation** — depends on Tasks C and D being defined (references Fly app names and deploy commands), but is primarily a runbook, not code

Tasks A and B can be implemented in parallel. Task C follows. Task D follows C. Task E can be drafted at any time but is only executable after everything else is deployed.

### Release Configuration

Configure the Mix release in the project's mix.exs targeting Unix, including runtime_tools for remote debugging. Set a static release cookie or generate one at build time and document it — this is required for remote console access to work for debugging on the deployed machine.

A Release module provides a `migrate/0` function that loads the app, discovers Ecto repos, and runs all pending migrations. This is invoked via a release eval command before the server starts.

The `migrate/0` function must:
- Load the application and its dependencies without starting the supervision tree (start only the Ecto adapter and its dependencies, not the full app)
- Discover repos via the application's `:ecto_repos` config key
- Run migrations for each repo in the "up" direction
- Be idempotent — running it when all migrations are already applied must be a no-op that exits cleanly with status 0
- Handle the case where the database file does not yet exist (first deploy) — the SQLite adapter creates the file automatically, but the parent directory must exist; fail with a clear error message if it does not

### Dockerfile

A multi-stage build following the standard Elixir release pattern. Create the Dockerfile at the project root.

**Build stage:** Uses the official hexpm/elixir Alpine image. Pin the Elixir and OTP versions to match the versions used in local development (check the project's version-pinning files for the current versions) to avoid cross-compilation surprises. Installs build dependencies: build-base (provides make, gcc, g++), git, and sqlite-dev (provides SQLite headers for exqlite's NIF compilation). Copies mix files, fetches and compiles deps, copies source, compiles the release in prod mode.

Note on Alpine and NIFs: exqlite compiles a NIF against musl libc on Alpine. This is well-trodden ground for exqlite specifically, but if additional NIFs are introduced in the future, verify musl compatibility.

**Runtime stage:** Minimal Alpine image with only runtime dependencies: libstdc++, libgcc, openssl, ncurses-libs, and sqlite-libs (the SQLite shared library). Copies the release from the build stage. Sets PORT to 8080 and DATABASE_PATH to /data/audit.db as defaults via ENV directives. Creates the /data directory in the image so the volume mount point exists even when no volume is attached (for local Docker testing).

The entry command invokes a startup script (see below) that first runs migration via release eval and then execs the release start command.

Note: the runtime.exs default for PORT is 4000 (for local dev), but the Dockerfile's ENV PORT of 8080 overrides this for the deployed environment. This is intentional — dev and prod use different ports.

**Pinning the Alpine base image version:** Both the build stage and the runtime stage should pin to the same Alpine minor version to avoid musl libc version mismatches between the NIF compiled in the build stage and the shared libraries available at runtime.

### .dockerignore

Create a .dockerignore file at the project root that excludes at minimum: _build, .git, deps, test, .elixir_ls, .env, markdown files (except README if needed), and any local data files. This is load-bearing for build performance — without it, the entire _build and deps tree gets sent as build context to Docker, which can be hundreds of megabytes.

### Startup Entrypoint Script

Create a shell script at rel/entrypoint.sh that the Dockerfile copies into the image and sets as the ENTRYPOINT or CMD. The script must:

1. Run migrations via the release eval command for the migrate function
2. If the migration command exits with a non-zero code, the script must also exit with a non-zero code — it must not proceed to start the server. Log a clear message indicating migration failure.
3. If migration succeeds, exec into the release start command (using exec so the BEAM process becomes PID 1 and receives SIGTERM directly from Docker or Fly)

Using exec is critical: if the shell script remains as PID 1, SIGTERM goes to the shell, not the BEAM, and graceful shutdown may not work correctly.

The entrypoint script must be marked as executable in the repository (file permissions) and the Dockerfile must ensure it is executable in the image. A missing execute bit is a common source of "exec format error" failures on deploy.

### fly.toml

Key settings:

- **App name:** Use a distinct Fly app name from the Python server (for example, ex-code-remote) so both can coexist during the bake period. The Python agent discovers the server by URL, not app name, so this is purely organizational.
- **Region:** dfw (single region, matching the Python server)
- **Volume mount:** ex_code_remote_data at /data for the audit SQLite database. The volume must be created before the first deploy via the Fly CLI volume create command. Size should be at least 1 GB — the audit log is append-only and will grow over time, though a single-agent workload will take months to approach this limit.
- **auto_stop_machines set to false** — agents hold long-lived WebSocket connections; Fly's default auto-stop would sever every agent when the machine looks idle over HTTP. This setting is critical and must not regress.
- **min_machines_running set to 1** — always keep at least one instance up
- **Internal port:** 8080 with force_https enabled
- **Health check:** Configure an HTTP health check against the /health endpoint on port 8080 (this endpoint is defined in SPEC-3's router). Set the interval to 15 seconds and the timeout to 5 seconds. A grace period of 30 seconds should be configured to allow time for migrations to run before health checks begin failing the deploy.
- **Kill signal and timeout:** Use SIGTERM (the default) with a kill_timeout of 30 seconds. This gives the BEAM time to drain active WebSocket connections and close the Ecto repo before the process is forcefully killed.

### Runtime Config

All production configuration reads from environment variables in runtime.exs:

- PORT: default 4000 locally, overridden to 8080 by the Dockerfile ENV for production
- AUTH_TOKEN: required in prod — the application refuses to start without it (per SPEC-3). Must also reject empty strings, not just missing values.
- DATABASE_PATH: default /data/audit.db in prod, a project-relative path in dev
- JSON log formatter for production (per SPEC-7)
- PHX_SERVER or equivalent flag to ensure the HTTP endpoint starts in the release (releases do not start endpoints by default unless configured; this is a common gotcha with Phoenix-based releases)

The runtime.exs must guard on the prod environment for production-only settings (like requiring AUTH_TOKEN) so that dev and test environments are not affected.

If AUTH_TOKEN is missing or empty in prod, the application must raise a clear error message that names the missing variable. The default Elixir "missing environment variable" error is acceptable if it names the variable.

### Secrets

AUTH_TOKEN is set via the Fly secrets set command using 32 bytes of random hex (64 characters). This is the same shared secret used for agent WebSocket auth and the /commands debug endpoint (per SPEC-3).

Note: during the bake period, both the old Python server and the new Elixir server will have the same auth token. This is safe because the agent connects to exactly one server at a time via its RELAY_URL — there is no risk of cross-connection as long as the URLs are distinct.

### Deploy Behavior and SQLite Safety

When Fly deploys, it replaces the machine. The volume is detached from the old machine and attached to the new one. There is a brief window during this transition where the server is down. This is acceptable for the bake period since the agent will reconnect automatically.

SQLite writes are not at risk of corruption during deploy because the process receives a shutdown signal (SIGTERM) and the OTP application shuts down gracefully, closing the Ecto repo and its database connections before the volume is detached. Ensure the Dockerfile does not override the SIGTERM handling — the BEAM's default signal handling is correct here. Specifically: the entrypoint script must use exec to hand off PID 1 to the BEAM (see Startup Entrypoint Script section).

If the volume is not created before the first deploy, the deploy will fail because the volume mount references a volume that does not exist. The error from Fly is clear, but the cutover plan should call this out as a prerequisite step.

### Cutover Plan

The new server runs alongside the Python server at a different Fly app name. The Python agent switches over with a single env-var change. The plan:

1. **Create the Fly app and volume.** Create the app under the appropriate Fly organization, then create the persistent volume in the dfw region with at least 1 GB. The volume must be created before the first deploy — deploying without it will fail.
2. **Set secrets.** Set AUTH_TOKEN via the Fly secrets set command using the same token value the Python server uses (or a new 32-byte hex token if the Python token format is incompatible).
3. **Deploy** from a clean checkout.
4. **Verify health** by hitting the new server's /health endpoint over HTTPS. Expect a 200 response.
5. **Verify logs** show structured JSON output, migration ran successfully, and the server started without errors.
6. **Verify the server is not auto-stopping** by checking machine status after at least 30 minutes of idle time. This confirms the auto_stop_machines setting is correct.
7. **Switch the agent** by updating RELAY_URL in the agent's environment to point at the new server's WebSocket URL (matching the path defined in the router from SPEC-3). Restart the agent.
8. **Verify the agent connection** by checking logs for the agent connected message (per SPEC-2's connection lifecycle).
9. **Switch the MCP client** in Claude.ai connector settings to point at the new server's MCP endpoint (matching the path defined in the router from SPEC-5).
10. **Verify MCP** by listing tools and dispatching a test command through the MCP client.
11. **Bake for a week.** Monitor disconnect counts, command latency, and error rates in logs (see bake monitoring criteria below). Both servers stay up during this period; the Python server has no agent attached so it's idle.
12. **Retire the Python server** once the new one has proven stable.

### Bake Monitoring Criteria

During the one-week bake period, the following conditions must hold for the deploy to be considered stable:

- The agent maintains a persistent WebSocket connection with no unexpected disconnects (reconnects caused by deploy or machine restart are expected and do not count)
- Commands dispatched via MCP complete successfully — no timeouts or unmatched correlation IDs in logs
- The audit log is being written to (verify by checking the SQLite file size grows or by querying it via remote console or release eval)
- Structured JSON logs are flowing to Fly's log aggregator (verify via the Fly logs command — every line should be valid JSON, per SPEC-7)
- The machine is not being auto-stopped — uptime remains continuous between intentional restarts (verify via machine status showing uptime greater than the time since last intentional restart)
- No OOM kills or unexpected machine restarts (check machine status for restart count)
- Memory usage remains stable over the bake period — no sustained growth that would suggest a leak. Check machine metrics or run remote console diagnostics if memory trends upward.

If any of these conditions fail, follow the rollback procedure.

### Rollback

If the new server misbehaves during the bake:

1. Revert RELAY_URL on the agent to point back to the Python server. Restart the agent.
2. Revert the MCP connector URL in Claude.ai settings to the Python server.
3. Agent and MCP client reconnect to the Python server.
4. File bugs, fix, redeploy, try again.

Nothing in the new server is destructive to the Python server — they share no state. Rollback is instant because the Python server has been running the entire bake period.

Note: the rollback procedure assumes the Python server remains healthy throughout the bake. If the Python server experiences its own failure during the bake period (for example, a Fly machine restart or a bug unrelated to the migration), it may not be in a ready state for immediate rollback. The bake period operator should periodically verify the Python server is still responding to its own health endpoint.

### Definition of Done for This Spec

This spec is done when the Elixir server is deployed to Fly, the Python agent is connected to it, and the MCP client is pointed at it. The bake period then begins. The bake period itself is not part of this spec's implementation — it is a post-deploy observation window. Retiring the Python server is a separate decision made after the bake, not a deliverable of this spec.

## How to Evaluate

### Success Criteria

Release and local build:

- [ ] Mix release produces a working release locally (verify by running the release start command outside of Mix)
- [ ] Docker build succeeds and produces a runnable image
- [ ] The Docker image starts the server and /health responds with 200 when run locally with the AUTH_TOKEN environment variable set
- [ ] Migration runs on container start (verified by the migration log line appearing in container stdout before the server started message)
- [ ] Running the container a second time against the same volume does not re-run already-applied migrations (idempotency)
- [ ] Logs in the Docker container are structured JSON with one JSON object per line (per SPEC-7)
- [ ] Container exits with a non-zero code when AUTH_TOKEN is not set
- [ ] Container exits with a non-zero code when AUTH_TOKEN is set to an empty string

Fly deployment:

- [ ] Deploy succeeds from a clean checkout
- [ ] Deployed app responds to /health over HTTPS with 200
- [ ] Volume mounts correctly at /data (verify via SSH console and checking the audit database file exists)
- [ ] Audit DB persists across a deploy (write a record, deploy, verify record still exists)
- [ ] Audit DB persists across a machine restart
- [ ] Migrations run on first start (verified in logs)
- [ ] Fly machine is not being auto-stopped (verified by checking uptime via machine status after 30 or more minutes idle)

End-to-end integration:

- [ ] Python agent successfully connects when pointed at the new RELAY_URL
- [ ] Agent reconnects automatically after a machine restart
- [ ] Agent reconnects automatically after a deploy
- [ ] An MCP client can list tools via the new server
- [ ] An MCP client can dispatch a run_shell_command against the connected agent and receive a result
- [ ] The audit log contains entries for the commands dispatched during testing (verifies the full write path from SPEC-6 works end-to-end in production)

### Tests

Tests should be included with the implementation changes:

- **Release module test**: the migrate/0 function runs successfully against a test Repo and is idempotent (calling it twice in succession completes without error, and the second call applies zero migrations). This test uses ExUnit and runs as part of the standard test suite.
- **Dockerfile smoke test**: build the image and run it locally with a test auth token, hit /health, assert 200. This can be a shell script in the project (not an ExUnit test) since it requires Docker. Document how to run it in the test file or a comment.
- **Startup failure test**: verify that the container exits with a non-zero code if AUTH_TOKEN is not set. This can be part of the same shell script as the Dockerfile smoke test — run the container without AUTH_TOKEN, assert the exit code is non-zero and the container is not running.

There is also a manual deploy validation checklist (performed once per deploy, not automated):

- Deploy from clean checkout succeeds
- Logs show migration ran and server started, in structured JSON format
- /health returns 200 over HTTPS
- Python agent connects, check_agent_status via MCP shows the machine
- run_shell_command returns expected output
- After machine restart, agent reconnects and commands work again
- After deploy, agent reconnects and audit DB retains prior data
- After 30 minutes idle, machine is still running (auto-stop disabled)

### Validation

- Standard test suite passes (release module tests)
- Dockerfile smoke test script passes
- Deploy validation checklist completed against the deployed app

## Edge Cases and Failure Modes

The following failure scenarios should be understood by implementers:

- **Volume not created before first deploy:** The deploy will fail with an error about the missing volume. This is expected — the cutover plan calls out volume creation as a prerequisite. No code-level handling is needed.
- **DATABASE_PATH parent directory does not exist:** The Release module's migrate/0 should fail with a clear error if the parent directory of the database file does not exist, rather than allowing SQLite to produce a cryptic error. The Dockerfile creates /data in the image, and the volume mount replaces it, so this should only be an issue in misconfigured local testing.
- **Disk full on volume:** SQLite will return a write error, which Ecto surfaces as a changeset or query error. The application does not need special handling for this — normal error logging is sufficient. The operator should monitor volume usage during the bake period.
- **Migration failure on deploy:** If a migration fails (for example, due to a bug in the migration SQL), the entrypoint script exits non-zero, the container fails to start, and Fly marks the deploy as failed and does not route traffic to it. The previous machine (if any) continues running. The fix is to correct the migration and redeploy.
- **SIGTERM during active command:** When a deploy or restart sends SIGTERM, the BEAM begins shutting down the supervision tree. Active WebSocket connections will be closed. In-flight commands will not complete — the agent will reconnect and the MCP client will see a timeout or disconnect. This is acceptable; the agent's reconnect logic (SPEC-2) handles it.
- **Migration applied against corrupt or unexpected database state:** If the audit database file on the volume has been corrupted (for example, due to a previous ungraceful shutdown or disk issue), migrations may fail in unexpected ways. The entrypoint script catches this as a non-zero exit and the deploy fails cleanly. Recovery in this case requires SSH access to inspect or delete the database file on the volume, then redeploying to start fresh. This is acceptable since audit data loss during the bake period is not critical.
- **Fly platform outage or machine migration:** Fly may move a machine to different hardware for maintenance. The volume follows the machine but there will be downtime. This is equivalent to a machine restart from the application's perspective — the agent reconnects automatically.

## Notes

- Single-machine, single-region is a hard constraint of the current architecture (WebSocket state is in-process). Multi-region or clustering is a future spec that would require a distributed registry. Not worth doing until there's a second region worth running in.
- The auto_stop_machines setting being false is non-obvious but critical. Fly's default is to stop machines that look idle, but HTTP-wise the machine looks idle even while holding an active WebSocket.
- The cutover keeps the old server alive during the bake so rollback is instant. The Python server has no agent attached during the bake, so it costs basically nothing.
- Machine restart is the rollout primitive once the app is live. For code changes, deploy does a rolling replace that will briefly drop the agent connection; the agent's built-in reconnect handles it.
- The .dockerignore file is load-bearing for build performance. Without it, the entire _build and deps tree gets sent as build context to Docker, which can be hundreds of megabytes.
- The exec in the entrypoint script is load-bearing for signal handling. Without it, SIGTERM hits the shell wrapper and the BEAM may not shut down gracefully.
- SPEC-9 (Tailscale integration) will layer on top of this deployment. That spec may introduce additional environment variables, Dockerfile changes, or fly.toml modifications. The deployment configuration in this spec should be treated as the baseline that SPEC-9 extends — nothing here should make Tailscale integration harder (for example, do not hardcode assumptions about network topology that Tailscale would change).

## Observations

- [decision] Mix release plus multi-stage Dockerfile plus Fly.io — boring, proven, matches standard Elixir deployment
- [decision] Single-region, single-machine — matches current architecture, revisit when clustering is needed
- [decision] auto_stop_machines set to false — agents hold long-lived connections, cannot survive auto-stop
- [decision] Cutover runs the new server alongside the old, switches agent via env var — instant rollback, zero data migration
- [decision] Migrations run on start via release eval command — no separate migration step, deploy is atomic
- [decision] Bake for a week before retiring the Python server — stability is the whole point of the port, prove it before committing
- [decision] Dockerfile must include SQLite libs for exqlite NIF — both build-time (headers plus compiler) and runtime (shared lib)
- [decision] Container must fail to start if AUTH_TOKEN is missing — fail loud, not silent
- [decision] Shell entrypoint chains migration then exec to server — if migration fails, container exits non-zero and Fly marks it unhealthy
- [decision] Entrypoint uses exec to hand PID 1 to the BEAM — required for correct SIGTERM handling and graceful shutdown
- [decision] Health check grace period of 30 seconds — migrations must complete before health checks start failing the deploy
- [constraint] WebSocket state is in-process, so we cannot horizontally scale without a distributed registry
- [constraint] Volume must be pre-created before first deploy — deploy alone does not create volumes
- [constraint] Alpine build and runtime stages must use the same Alpine minor version to avoid musl libc mismatch for NIF compatibility
- [risk] auto_stop_machines being false must not regress — add a deploy check or doc warning
- [risk] Audit DB on a Fly volume is a single point of failure with no backup strategy — acceptable for the bake period but should be addressed before the system is considered production-grade
- [risk] Kill timeout must be long enough for BEAM to drain connections — 30 seconds is conservative but safe
- [risk] Python server health should be periodically verified during bake to ensure rollback target is viable
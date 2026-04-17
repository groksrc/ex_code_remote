---
title: 'SPEC-1: Project Definition and Initialization'
type: spec
permalink: specs/spec-1-project-definition-and-initialization
tags:
- meta
- initialization
- architecture
status: implemented
---

# SPEC-1: Project Definition and Initialization

## Why

The existing `code-remote` Python implementation (`~/code/code-remote`) has chronic stability problems: multi-minute disconnects, event-loop stalls, subprocesses stuck in uninterruptible kernel wait, and result-correlation bugs from a polling-based SQLite queue. The most recent commits in that repo are all symptom-fighting patches (event-loop watchdog, process-group kills, background reapers, dual keep-alive loops) that treat the pattern rather than the architecture.

**These are not theoretical concerns — they directly impact the person using the system.** When the server stalls, in-flight commands from Claude.ai time out silently, the agent shows as connected when it is not, and the user has to manually kill and restart processes to recover. The current system is unreliable enough that its operator cannot trust it for unattended use, which defeats the core value proposition of remote code execution via AI.

The root issue is that asyncio conflates too many responsibilities into one event loop. WebSocket message draining, command dispatch, keep-alive, and result collection all compete for the same cooperative scheduler. When any one of them blocks, the others degrade.

BEAM fixes this structurally:

- Preemptive per-process scheduling means one slow operation cannot stall others.
- Supervisors provide crash isolation per agent connection.
- GenServer + Registry replaces the polling-based SQLite correlation with in-memory reply routing.
- Bandit handles WebSocket keep-alive natively.

**The intended outcome of this rewrite is a server that stays connected, responds to commands within seconds, and recovers from faults without human intervention.** If we achieve that, the system becomes trustworthy enough to use as a persistent background tool — which is the entire point.

## What

`ex-code-remote` is an Elixir rewrite of the **server half** of code-remote. It preserves the existing WebSocket wire protocol to the Python agent so the agent can stay untouched during the port. The MCP interface exposed to Claude.ai (and any other MCP client) remains identical.

**In scope for the port:**

- MCP server (SSE transport) for AI clients
- Raw WebSocket endpoint for agent connections at `/ws/agent`
- Agent connection supervision and command routing by machine name
- In-memory command correlation (result futures held in process state, not polled from a database)
- Health check endpoint
- Audit log for command history (storage choice deferred to a later spec)

**Explicitly out of scope for the initial cut:**

- Rewriting the Python agent
- Tailscale private-network enforcement (defer until core is stable)
- Multi-region deployment
- Feature parity with every option from the Python server's CLI/env surface

**Scope boundary with SPEC-2:** SPEC-1 bootstraps the Mix project, adds all known dependencies, and wires Bandit with a minimal router containing only `/health` to prove the stack compiles and starts. SPEC-2 extends that router with the full HTTP skeleton, SSE endpoint, and WebSocket upgrade path. The health check created here is intentionally minimal and will be enriched in SPEC-2 with agent connection status.

**Cutover strategy:** The Elixir server must be able to run side-by-side with the Python server on a different port during validation. The Python server remains the production path until at minimum SPEC-5 (MCP tool surface) is complete and the Elixir server has been tested end-to-end with the real Python agent and a real MCP client. If at any point the Elixir rewrite proves unviable (for example, if ExMCP cannot support the required MCP integration), the Python server continues operating and this effort is discontinued. There is no point of no return in the spec sequence before SPEC-5.

**Affected areas:**

- Existing repository at `~/code/ex-code-remote` (already initialized, receives its first Mix scaffold in this spec)
- Future Fly.io deployment target (will eventually replace the current server)

## How (High Level)

### Stack

- **Elixir** 1.18+ on **Erlang/OTP** 27+
- **Bandit** — HTTP and WebSocket server
- **Plug** — HTTP middleware (no full Phoenix; follows Tidewave's minimal-deps approach — Tidewave is an open-source Elixir AI coding tool that hand-rolls its MCP integration as a Plug rather than pulling in full Phoenix)
- **ExMCP** (`== 0.9.1`) — MCP protocol implementation, mounted as a Plug. Pinned to an exact version because it is pre-1.0 and minor releases may contain breaking changes. Bump deliberately after reading the changelog.
- **Jason** — JSON encoding
- **Registry** + **DynamicSupervisor** (built-in) — one supervised GenServer per connected agent
- **WebSockAdapter** — raw WebSocket handler adapter for the agent endpoint. WebSock itself is a transitive dependency of WebSockAdapter and should not be listed as a direct dependency in mix.exs.

ExMCP is added as a dependency in SPEC-1 to validate that it resolves cleanly alongside the other deps, but it is not wired into the supervision tree or router until SPEC-5. The only runtime component in SPEC-1 is Bandit serving the Plug router.

**Dependency resolution risk:** ExMCP may pull in transitive dependencies that conflict with the versions of Bandit, Plug, or Jason listed above. If `mix deps.get` fails due to version conflicts, the resolution strategy is: first try relaxing Bandit or Plug version constraints (they are post-1.0 and stable), and only if that fails, remove ExMCP from the dependency list entirely and re-add it in SPEC-5 when it is actually needed. Document whatever resolution was required in the commit message.

### Wire Protocol Reference

The Python agent communicates with the server over a WebSocket connection using a JSON message envelope. The authoritative definition of this protocol lives in the existing Python codebase at `~/code/code-remote`. Before implementing SPEC-3, the engineer assigned to that spec must read the Python agent's WebSocket handler and message types to produce a protocol reference document or at minimum catalog the message types, required fields, and correlation ID scheme. SPEC-1 does not need to implement any of this, but it is called out here because this protocol boundary is the single most important contract in the system.

At a minimum, the following must be understood and documented before SPEC-3:

- The message envelope structure (JSON, with at least a type field and a correlation ID)
- The set of message types the agent sends and expects
- How the agent identifies itself (machine name registration on connect)
- The keep-alive and reconnection behavior expected by the agent

### Project Shape

Single-app Mix project (not umbrella), created with `mix new . --sup` run from within `~/code/ex-code-remote`. Using `.` as the path argument tells Mix to generate the scaffold in the current directory rather than creating a nested subdirectory. Mix will derive the application name from the directory name, converting hyphens to underscores (yielding app name `ex_code_remote` and module name `ExCodeRemote`).

Because the repository is already initialized, the directory is not empty (at minimum `.git` exists). Mix will skip any files that already exist and generate the rest. If Mix prompts for confirmation about generating into a non-empty directory, confirm and proceed.

Note that `mix new` does not generate a `config/` directory. The config files described below must be created manually after the scaffold is in place.

Target layout:

- `lib/ex_code_remote/application.ex` — top-level supervisor tree
- `lib/ex_code_remote/router.ex` — Plug router mounting MCP, `/ws/agent`, and `/health`
- `lib/ex_code_remote/mcp/server.ex` — ExMCP server definition and tool implementations
- `lib/ex_code_remote/agent/connection.ex` — GenServer per connected agent
- `lib/ex_code_remote/agent/registry.ex` — machine name to PID lookup
- `lib/ex_code_remote/agent/socket.ex` — WebSock handler bridging the socket to the GenServer
- `lib/ex_code_remote/commands/dispatcher.ex` — routes MCP tool calls to the right agent and awaits reply
- `specs/` — this file and future specs
- `config/` — config.exs and runtime.exs (manually created, not generated by mix new)
- `test/` — standard Mix test directory (generated by mix new)

For SPEC-1, only `application.ex`, `router.ex`, and the directory structure need to contain real logic. All other modules listed above should be created as empty modules (a `defmodule` with a `@moduledoc` describing the module's future responsibility and nothing else). This ensures the directory layout is in place and the project compiles, without introducing placeholder logic that will be thrown away.

The exact module names for stub files are:
- `ExCodeRemote.MCP.Server` in `lib/ex_code_remote/mcp/server.ex`
- `ExCodeRemote.Agent.Connection` in `lib/ex_code_remote/agent/connection.ex`
- `ExCodeRemote.Agent.Registry` in `lib/ex_code_remote/agent/registry.ex`
- `ExCodeRemote.Agent.Socket` in `lib/ex_code_remote/agent/socket.ex`
- `ExCodeRemote.Commands.Dispatcher` in `lib/ex_code_remote/commands/dispatcher.ex`

Each stub must have only a `defmodule` block with a `@moduledoc` string. No functions, no `use` declarations, no callbacks. The `@moduledoc` should be one or two sentences describing what the module will do in the spec that introduces it.

### Supervision Tree

The top-level Application supervisor owns the following children, started in this order:

1. **Registry** — named `ExCodeRemote.AgentRegistry`, used for machine-name-to-PID lookups. Started first because other processes depend on it. Use `keys: :unique` since each machine name maps to exactly one agent process.
2. **DynamicSupervisor** — named `ExCodeRemote.AgentSupervisor`, strategy `one_for_one`. Each connected agent will become a child of this supervisor in SPEC-3.
3. **Bandit** — serving the Plug router on a configurable port (default 4000, overridable via the `PORT` environment variable as an integer).

The Application supervisor itself should use `strategy: :one_for_one`. A crash in the Registry does not require restarting Bandit, and vice versa. The one exception to watch for: if the Registry crashes, existing agent processes will lose their registration. This is acceptable for SPEC-1 since no agents are connected yet; SPEC-3 should revisit whether the strategy needs to change.

This tree is intentionally flat. There is no intermediate supervisor grouping agents and the router because they have no shared failure mode. If a future spec introduces a process that should crash-together with the agents (such as the audit writer), it can introduce a subtree at that point.

For SPEC-1, only the Registry and Bandit need to be started. The DynamicSupervisor should be included in the tree so the supervision structure is established, but it will have no children until SPEC-3.

### Router Behavior

The router must be a `Plug.Router` with the following behavior:

- `GET /health` returns HTTP 200 with content type `application/json` and body `{"status": "ok"}`.
- All other routes return HTTP 404 with content type `application/json` and body `{"error": "not found"}`. This is accomplished by adding a catch-all match clause at the bottom of the router. Without this, Plug.Router raises a `Plug.Conn.NotSentError` for unmatched routes, which surfaces as a 500 error to clients.
- The router must `use Plug.Router`, call `plug :match` and `plug :dispatch`, and use `plug Plug.Parsers` with JSON support via Jason (specifying Jason as the JSON decoder). The Parsers plug is not strictly needed for the health endpoint but will be needed by SPEC-2 and costs nothing to add now.

**Content-type detail:** Plug includes `charset=utf-8` in the content-type header by default, so responses will have `application/json; charset=utf-8` rather than bare `application/json`. Tests and success criteria should treat any content-type value starting with `application/json` as a match.

### Configuration

`config/runtime.exs` reads the `PORT` environment variable and converts it to an integer. The conversion must handle the case where `PORT` is not set (fall back to 4000) and the case where `PORT` is set to a non-numeric string (log a warning and fall back to 4000, do not crash on startup). The port value is made available to the application via `Application.get_env(:ex_code_remote, :port)` or read directly in the supervision tree children list — either approach is acceptable as long as the Bandit child spec uses the resolved integer value.

A `config/config.exs` must also exist. Since there are no environment-specific config files yet, it only needs the Config import. If ExMCP or any other dependency requires a global JSON library configuration, add that here. Otherwise the file can contain only the Config import and nothing else.

Both config files must be created manually because `mix new` does not generate a config directory.

### Initialization Steps

1. Run `mix new . --sup` from within `~/code/ex-code-remote` to generate the scaffold in the existing repository root. Confirm if Mix prompts about the non-empty directory.
2. Add initial dependencies to `mix.exs`: Bandit, Plug, ExMCP (exact pin `== 0.9.1`), Jason, and WebSockAdapter. Do not add WebSock directly; WebSockAdapter depends on it and will pull it in transitively.
3. Run `mix deps.get` and verify it resolves cleanly. If ExMCP causes version conflicts, follow the resolution strategy described in the Stack section.
4. Create `config/config.exs` with the Config import and any global library configuration needed.
5. Create `config/runtime.exs` that reads the `PORT` environment variable with integer parsing and a fallback to 4000.
6. Wire the supervision tree described above into `application.ex` (Registry, DynamicSupervisor, Bandit in that order).
7. Implement `router.ex` as a `Plug.Router` with a single `GET /health` route and a catch-all 404 handler.
8. Create stub modules for the remaining files in the project layout, following the exact module names listed in the Project Shape section.
9. Create the `specs/` directory and commit this spec as `specs/SPEC-1.md`.
10. Write tests: health check endpoint test, 404 handler test, supervision tree startup test, and PORT configuration test.
11. Verify `mix compile --warnings-as-errors` is clean.
12. Verify `mix test` passes.
13. Verify `mix format --check-formatted` passes. If it does not, run the formatter and include the changes.
14. Verify `mix run --no-halt` starts and `curl localhost:4000/health` returns the expected JSON.

Steps 1 through 3 must be done in sequence. Steps 4 through 9 can be done in any order after step 3 completes, as they are independent of each other. Steps 10 through 14 must follow after all prior steps are complete and must be done in sequence.

Git: repository is already initialized at `~/code/ex-code-remote`. An initial commit will be made after SPEC-1 lands and the mix scaffold is in place.

### Architectural Invariants

These are the rules that the rest of the specs must not violate. They exist to prevent re-creating the Python version's stability issues.

- **One GenServer per connected agent.** Machine name is the Registry key. Crashes are isolated to a single agent. If a GenServer crashes, only that agent's in-flight commands are lost; all other agents continue unaffected.
- **Command correlation lives in memory, not in a database.** A `GenServer.call` from the MCP tool handler holds a `from` reference; when the agent's result frame arrives on the socket, the reply is sent directly to the waiting caller. The audit log is written alongside, never polled.
- **The audit store is write-only from the business logic's perspective.** It records what happened; it never drives request/response flow.
- **Keep-alive is Bandit's responsibility.** No hand-rolled ping loops in application code.
- **Subprocess lifecycle stays on the agent side.** The server does not need to know about uninterruptible-sleep processes or process groups. The Python agent already handles that correctly.
- **No shared mutable state outside of supervised processes.** ETS/Registry is allowed only where ownership is clear and supervised.
- **GenServer.call timeouts are explicit, not infinite.** Every command dispatched to an agent must have a bounded timeout. The default should be generous (30 seconds or similar) but never `:infinity`. This prevents caller processes from hanging indefinitely if an agent disappears between receiving a command and sending a reply.

## How to Evaluate

### Definition of Done

This spec is done when the Elixir project compiles, starts, and serves a health check — proving that the dependency stack is sound and the supervision tree is wired correctly. No user-facing behavior changes. The Python server remains the production path. This is pure foundation work; its value is measured by whether subsequent specs can build on it without rework.

### Success Criteria

- [ ] `~/code/ex-code-remote` contains a working Mix project in the existing git repository
- [ ] `specs/SPEC-1.md` committed as the first spec
- [ ] `mix new --sup` scaffold in place with all dependencies listed in the Stack section
- [ ] `mix deps.get` resolves cleanly against Hex with no unresolvable version conflicts
- [ ] `mix compile --warnings-as-errors` succeeds with zero warnings
- [ ] `mix format --check-formatted` passes with no formatting violations
- [ ] Supervision tree starts Registry, DynamicSupervisor, and Bandit in the described order
- [ ] `config/runtime.exs` reads `PORT` from the environment with a default of 4000 and handles non-numeric values gracefully
- [ ] `mix run --no-halt` starts Bandit and `curl localhost:4000/health` returns HTTP 200 with body `{"status": "ok"}` and a content type starting with `application/json`
- [ ] `curl` to any undefined route (such as `localhost:4000/nonexistent`) returns HTTP 404 with body `{"error": "not found"}` and a content type starting with `application/json`
- [ ] Directory layout matches the project shape above, with all five stub modules present and compiling
- [ ] Each stub module contains only a `defmodule` with a `@moduledoc` and no function definitions
- [ ] `mix test` passes with at least one test exercising the health check endpoint
- [ ] No Phoenix, Ecto, or LiveView dependencies appear in `mix.exs` or `mix.lock`

### Tests

Tests should be included with the implementation changes. At this stage:

- A `Plug.Test`-based test that sends `GET /health` to the router and asserts HTTP 200 status, a content type starting with `application/json` (to account for Plug appending charset), and `{"status": "ok"}` body parsed as JSON (not string comparison, since key ordering in JSON is not guaranteed).
- A `Plug.Test`-based test that sends `GET /nonexistent` to the router and asserts HTTP 404 status, a content type starting with `application/json`, and `{"error": "not found"}` body parsed as JSON.
- A test that the application supervision tree starts all expected children. The default test generated by `mix new --sup` only asserts `true` and does not actually verify the supervision tree; replace or supplement it with a test that confirms the Registry and DynamicSupervisor are running by name after the application starts (for example, by checking that the named processes are alive).
- A test for PORT configuration: verify that the default port is 4000 when the `PORT` environment variable is not set. Optionally verify that a non-numeric `PORT` value falls back to 4000 rather than crashing. These tests may need to manipulate environment variables, so take care to restore the original state in test cleanup.

All tests should use `Plug.Test` to dispatch requests to the router module directly. Do not start Bandit in tests for SPEC-1; test the router in isolation. This avoids port-binding conflicts when tests run in parallel or on CI.

### Validation

After tests pass, perform a manual smoke test to confirm end-to-end behavior:

- `mix deps.get` resolves cleanly against Hex
- `mix compile --warnings-as-errors` succeeds
- `mix format --check-formatted` passes
- `mix run --no-halt` starts without errors in the console output
- `curl -i localhost:4000/health` returns HTTP 200 with a content-type header starting with `application/json` and `{"status": "ok"}` body
- `curl -i localhost:4000/nonexistent` returns HTTP 404
- Ctrl-C cleanly shuts down the application

## Notes

- Subsequent specs will cover, roughly in order:
  - **SPEC-2**: HTTP skeleton (Bandit, Plug, SSE endpoint, WebSocket upgrade path)
  - **SPEC-3**: Agent WebSocket and connection lifecycle (requires wire protocol documentation)
  - **SPEC-4**: Command dispatch and in-memory result correlation
  - **SPEC-5**: MCP tool surface (ExMCP wired into the router and supervision tree)
  - **SPEC-6**: Audit log
  - **SPEC-7**: Observability
  - **SPEC-8**: Deployment
  - **SPEC-9**: Tailscale private-network enforcement
- No attempt at feature parity in the initial cut. The goal of the port is to get the architecture right, then restore features one at a time on a foundation that does not require symptom-patching.
- SPEC-3 has a hard prerequisite: the wire protocol between the server and the Python agent must be documented before implementation begins. The Python source at `~/code/code-remote` is the source of truth.
- **The first end-to-end validation of the rewrite happens at SPEC-5**, when a real MCP client can send a command through the Elixir server to a real Python agent and get a result back. That is the earliest point at which we can confirm the architecture actually solves the reliability problems. Plan to run a structured comparison test at that milestone: same set of commands, same agent, Python server versus Elixir server, measuring connection stability, command latency, and recovery from simulated faults.

## Observations

- [decision] Plain Plug + Bandit instead of full Phoenix — follows the precedent set by Tidewave (an open-source Elixir AI coding tool) of hand-rolling MCP as a Plug, avoids LiveView/Ecto overhead for a service with no UI
- [decision] ExMCP chosen over Anubis on the basis of its conformance test suite (223/223 client, 39/39 server) and recent active development (v0.9.1 on 2026-04-11, five releases in five weeks)
- [decision] Python agent stays untouched for the initial port — preserves the wire protocol and lets the port focus on the server's architectural problems
- [decision] Single-app Mix project rather than umbrella — the server is one bounded concern
- [decision] ExMCP pinned to exact version (== 0.9.1) rather than pessimistic (~> 0.9.1) because pre-1.0 libraries may ship breaking changes in patch releases
- [constraint] Must continue to speak the MCP SSE transport that Claude.ai's connector uses
- [constraint] Must preserve the agent's current WebSocket wire protocol so the Python agent does not need to change
- [constraint] Port 4000 chosen as default because it is Bandit's conventional default; must be overridable via PORT environment variable for deployment flexibility
- [pattern] Registry + DynamicSupervisor for per-connection GenServers is the canonical BEAM pattern, validated by Tidewave's source tree
- [risk] ExMCP is pre-1.0 (v0.9.x); pinned to exact version in `mix.exs`. If ExMCP's Plug integration does not behave as expected when wired in at SPEC-5, the fallback is to implement MCP SSE transport directly using Plug and Jason — the protocol is simple enough that a hand-rolled implementation is viable
- [risk] ExMCP version 0.9.1 must be verified to exist on Hex before starting implementation. If it does not exist (the version may have been yanked or the latest version may differ), use the latest available 0.x release and pin it with an exact match. Update this spec with the actual version used.
- [risk] The wire protocol between the server and the Python agent is not formally documented. It exists only as implementation in the Python codebase. If the protocol has undocumented edge cases or implicit behaviors, they will surface during SPEC-3 testing against the real agent. Mitigate by reading the Python agent source before starting SPEC-3.
- [risk] Running `mix new` in the existing non-empty repository directory may prompt for confirmation or skip files that already exist. This is expected and safe — confirm the prompt and verify the generated output matches the expected scaffold.
- [risk] This rewrite carries the inherent risk of any ground-up rebuild: it takes longer than expected and delivers no user value until the full stack is integrated. The cutover strategy (side-by-side operation, no point of no return before SPEC-5) mitigates this, but the team should be honest about progress at the SPEC-5 milestone. If the Elixir server is not demonstrably more reliable than the Python server at that point, we should stop and reconsider.
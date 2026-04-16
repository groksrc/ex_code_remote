---
title: 'SPEC-1: Project Definition and Initialization'
type: spec
permalink: specs/spec-1-project-definition-and-initialization
tags:
- meta
- initialization
- architecture
---

# SPEC-1: Project Definition and Initialization

## Why

The existing `code-remote` Python implementation (`~/code/code-remote`) has chronic stability problems: multi-minute disconnects, event-loop stalls, subprocesses stuck in uninterruptible kernel wait, and result-correlation bugs from a polling-based SQLite queue. The most recent commits in that repo are all symptom-fighting patches (event-loop watchdog, process-group kills, background reapers, dual keep-alive loops) that treat the pattern rather than the architecture.

The root issue is that asyncio conflates too many responsibilities into one event loop. WebSocket message draining, command dispatch, keep-alive, and result collection all compete for the same cooperative scheduler. When any one of them blocks, the others degrade.

BEAM fixes this structurally:

- Preemptive per-process scheduling means one slow operation cannot stall others.
- Supervisors provide crash isolation per agent connection.
- GenServer + Registry replaces the polling-based SQLite correlation with in-memory reply routing.
- Bandit handles WebSocket keep-alive natively.

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

**Affected areas:**

- New repository at `~/code/ex-code-remote`
- Future Fly.io deployment target (will eventually replace the current server)

## How (High Level)

### Stack

- **Elixir** 1.18+ on **Erlang/OTP** 27+
- **Bandit** — HTTP and WebSocket server
- **Plug** — HTTP middleware (no full Phoenix; follows Tidewave's minimal-deps approach)
- **ExMCP** (`~> 0.9.1`) — MCP protocol implementation, mounted as a Plug
- **Jason** — JSON encoding
- **Registry** + **DynamicSupervisor** (built-in) — one supervised GenServer per connected agent
- **WebSock / WebSockAdapter** — raw WebSocket handler for the agent endpoint

### Project Shape

Single-app Mix project (not umbrella), created with `mix new ex_code_remote --sup`. Target layout:

- `lib/ex_code_remote/application.ex` — top-level supervisor tree
- `lib/ex_code_remote/router.ex` — Plug router mounting MCP, `/ws/agent`, and `/health`
- `lib/ex_code_remote/mcp/server.ex` — ExMCP server definition and tool implementations
- `lib/ex_code_remote/agent/connection.ex` — GenServer per connected agent
- `lib/ex_code_remote/agent/registry.ex` — machine name to PID lookup
- `lib/ex_code_remote/agent/socket.ex` — WebSock handler bridging the socket to the GenServer
- `lib/ex_code_remote/commands/dispatcher.ex` — routes MCP tool calls to the right agent and awaits reply
- `specs/` — this file and future specs
- `test/` and `config/` — standard Mix directories

### Initialization Steps

1. Run `mix new ex_code_remote --sup` inside `~/code/ex-code-remote`
2. Add initial dependencies to `mix.exs`: Bandit, Plug, ExMCP, and Jason
3. Run `mix deps.get`
4. Wire Bandit into the Application supervisor as a child spec, serving a minimal Plug.Router with a `/health` route
5. Verify `mix compile` is clean with zero warnings
6. Verify `mix run --no-halt` starts and `curl localhost:4000/health` responds

Git: repository is already initialized at `~/code/ex-code-remote`. An initial commit will be made after SPEC-1 lands and the mix scaffold is in place.

### Architectural Invariants

These are the rules that the rest of the specs must not violate. They exist to prevent re-creating the Python version's stability issues.

- **One GenServer per connected agent.** Machine name is the Registry key. Crashes are isolated to a single agent.
- **Command correlation lives in memory, not in a database.** A `GenServer.call` from the MCP tool handler holds a `from` reference; when the agent's result frame arrives on the socket, the reply is sent directly to the waiting caller. The audit log is written alongside, never polled.
- **The audit store is write-only from the business logic's perspective.** It records what happened; it never drives request/response flow.
- **Keep-alive is Bandit's responsibility.** No hand-rolled ping loops in application code.
- **Subprocess lifecycle stays on the agent side.** The server does not need to know about D-state or process groups. The Python agent already handles that correctly.
- **No shared mutable state outside of supervised processes.** ETS/Registry is allowed only where ownership is clear and supervised.

## How to Evaluate

### Success Criteria

- [ ] `~/code/ex-code-remote` exists as a git repository
- [ ] `specs/SPEC-1.md` committed as the first spec
- [ ] `mix new --sup` scaffold in place with dependencies from the list above
- [ ] `mix compile` succeeds with zero warnings
- [ ] `mix run --no-halt` starts Bandit and `curl localhost:4000/health` returns a 200 JSON response
- [ ] Directory layout matches the shape above (directories created even if files are stubs)

### Tests

Tests should be included with the implementation changes. At this stage, a basic test that the router responds to `/health` with 200 and a JSON body is sufficient.

### Validation

- `mix deps.get` resolves cleanly against Hex
- `mix compile --warnings-as-errors` succeeds
- Health check smoke test passes from a clean `mix run --no-halt`

## Notes

- Subsequent specs will cover, roughly in order:
  - **SPEC-2**: HTTP skeleton (Bandit, Plug, `/health`)
  - **SPEC-3**: Agent WebSocket and connection lifecycle
  - **SPEC-4**: Command dispatch and in-memory result correlation
  - **SPEC-5**: MCP tool surface
  - **SPEC-6**: Audit log
  - **SPEC-7**: Observability
  - **SPEC-8**: Deployment
  - **SPEC-9**: Tailscale private-network enforcement
- No attempt at feature parity in the initial cut. The goal of the port is to get the architecture right, then restore features one at a time on a foundation that does not require symptom-patching.

## Observations

- [decision] Plain Plug + Bandit instead of full Phoenix — follows Tidewave's precedent of hand-rolling MCP as a Plug, avoids LiveView/Ecto overhead for a service with no UI
- [decision] ExMCP chosen over Anubis on the basis of its conformance test suite (223/223 client, 39/39 server) and recent active development (v0.9.1 on 2026-04-11, five releases in five weeks)
- [decision] Python agent stays untouched for the initial port — preserves the wire protocol and lets the port focus on the server's architectural problems
- [decision] Single-app Mix project rather than umbrella — the server is one bounded concern
- [constraint] Must continue to speak the MCP SSE transport that Claude.ai's connector uses
- [constraint] Must preserve the agent's current WebSocket wire protocol so the Python agent does not need to change
- [pattern] Registry + DynamicSupervisor for per-connection GenServers is the canonical BEAM pattern, validated by Tidewave's source tree
- [risk] ExMCP is pre-1.0 (v0.9.x); pin tightly in `mix.exs` and expect minor API churn until 1.0

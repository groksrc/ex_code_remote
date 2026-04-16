---
title: 'SPEC-3: Agent WebSocket and Connection Lifecycle'
type: spec
permalink: specs/spec-3-agent-websocket-and-connection-lifecycle
tags:
- websocket
- agent
- supervision
- registry
- protocol
---

# SPEC-3: Agent WebSocket and Connection Lifecycle

Status: Spec-Reviewed

## Why

The server needs to accept persistent WebSocket connections from one or more agents, each identified by a machine name, and keep those connections supervised so that a crashed connection does not take down the server or affect other agents. This is the BEAM equivalent of the Python server's `ConnectionManager` dict — except crash-isolated and without a shared event loop.

Two architectural invariants from SPEC-1 apply directly here:

1. **One GenServer per connected agent**, registered by machine name.
2. **Command correlation lives in memory**, which means the GenServer that owns the socket must also own the in-flight command state (implemented in SPEC-4).

This spec lands the connection lifecycle — connect, authenticate, register, disconnect, reconnect — and **freezes the wire protocol** so the existing Python agent can reconnect to this server with only a `RELAY_URL` change. It stubs out the command path: the Connection GenServer accepts `dispatch` calls from upstream but replies with `{:error, :not_implemented}`. SPEC-4 removes the stub.

**Customer impact:** The Python server's connection management is the root cause of the reliability problems that motivated this port. When a connection dies in the Python server, the shared event loop and mutable dict-based ConnectionManager can leave the system in an inconsistent state — stale entries, orphaned commands, and cascading failures that affect all connected agents. This spec replaces that with crash-isolated, per-agent processes where a single connection failure is structurally incapable of affecting other agents. For the user, this means that a network hiccup on one machine no longer risks destabilizing their entire remote development workflow.

**The frozen wire protocol is the highest-value decision in this spec.** It is what makes the port a zero-disruption migration: the Python agent does not need any code changes to connect to the new server. The user changes a single environment variable and the agent reconnects. If anything goes wrong during the SPEC-8 bake-off, they change it back. This clean migration path is only possible because we are committing to exact protocol compatibility here.

## What

**Dependencies:** This spec depends on SPEC-1 (architecture decisions, supervision topology) and SPEC-2 (project scaffold, Bandit and Plug setup). Both must be complete before implementation begins. SPEC-4 (command correlation), SPEC-5 (MCP tool handlers), and SPEC-6 (audit) all depend on modules and APIs established here.

**In scope:**

- The agent WebSocket wire protocol, documented inline and frozen
- `ExCodeRemote.Agent` — the public facade module for agent operations
- `ExCodeRemote.Agent.Registry` — a Registry keyed by machine name
- `ExCodeRemote.Agent.Supervisor` — a DynamicSupervisor that owns all connection processes
- `ExCodeRemote.Agent.Connection` — the GenServer per connected agent
- `ExCodeRemote.Agent.Socket` — the WebSock handler that bridges the raw socket to the GenServer
- Connection upgrade route at `/ws/agent` in `ExCodeRemote.Router`
- Query-parameter auth (`token`, `machine`) with constant-time token comparison
- Close codes for rejection paths
- Public API: `Agent.connected?/1`, `Agent.list/0`, `Agent.start_connection/2`, `Agent.stop_connection/1`, `Agent.dispatch/3` (stub)

**Out of scope:**

- Command result correlation (SPEC-4)
- MCP tool handlers calling `Agent.dispatch/3` (SPEC-5)
- Tailscale IP checks (SPEC-9)
- Audit writes on connect/disconnect (SPEC-6)
- Server-initiated periodic keepalive scheduling and pong timeout detection — this spec establishes the ping/pong frame types, but the decision of whether and how often the server should proactively ping agents, and what to do if a pong is not received, is deferred. A future spec should define keepalive intervals and liveness timeout behavior. **Note: this deferral is a known gap. Stale connections that appear live in the Registry but have a dead socket are exactly the kind of subtle reliability bug that caused the port in the first place. The passive ping/pong handling defined here is sufficient for the initial bake-off (SPEC-8) because the Python agent manages its own reconnection, but server-initiated liveness detection should be prioritized immediately after the core specs land — before the Python server is retired.**
- Frame size limits — this spec does not impose a maximum frame size. If resource exhaustion from oversized frames becomes a concern, a limit should be introduced in a future spec, coordinated with the Python agent.

## Agent WebSocket Wire Protocol (frozen)

This is the contract between the Elixir server and the Python agent. It must match what the existing agent at `~/code/code-remote/agent/agent.py` sends and receives. Any future change to this protocol requires a new spec and a coordinated deploy of both sides.

### Application-Level vs Transport-Level Ping/Pong

The ping and pong frames described in this section are **application-level** messages — JSON text frames with a `type` field, such as `{"type": "ping"}` and `{"type": "pong"}`. These are distinct from WebSocket protocol-level ping and pong opcodes, which exist at the transport layer and are handled automatically by the WebSocket library (Bandit). The implementation must not confuse the two: transport-level ping/pong is invisible to application code, while application-level ping/pong flows through the normal frame handling path described below.

### Connection URL

The agent connects to `wss://<host>/ws/agent?token=<auth_token>&machine=<machine_name>`.

- `token` — shared secret, compared constant-time against `AUTH_TOKEN` env var.
- `machine` — non-empty string identifying the agent; must be unique across connected agents. A reconnect with the same name replaces the old entry. Machine names are treated as opaque strings with no character or length restrictions beyond being non-empty, since they originate from the Python agent's configuration.

### Frame Format

All frames are JSON text frames. Every frame has a `type` field. Binary frames are rejected — the server must close the connection with code 1003 (unsupported data) if it receives a binary frame.

**Server to Agent:**

| type | fields | meaning |
|---|---|---|
| `execute` | `id`, `command_type`, `command`, `path`, `content`, `working_dir`, `timeout` | Execute a command. `id` is generated by the server. |
| `ping` | — | Keep-alive. Agent must reply with `pong`. |
| `pong` | — | Response to an agent `ping`. |

**Agent to Server:**

| type | fields | meaning |
|---|---|---|
| `result` | `id`, `status`, `output`, `error`, `exit_code` | Result of a previously-dispatched `execute`. `status` is one of `completed`, `failed`, or `timeout`. |
| `ping` | — | Keep-alive from the agent. Server replies with `pong`. |
| `pong` | — | Response to a server `ping`. |

### Close Codes

| code | reason | when |
|---|---|---|
| `4002` | `missing_machine` | `machine` query param absent or empty |
| `4003` | `forbidden` | bad or missing `token` |
| `1000` | normal close | agent disconnects cleanly |
| `1001` | going away | server is shutting down gracefully |
| `1003` | unsupported data | binary frame received (text-only protocol) |
| `1011` | internal error | unexpected server exception |

### Protocol Invariants

- The server never sends anything other than `execute`, `ping`, or `pong`.
- The agent never sends anything other than `result`, `ping`, or `pong`.
- Unknown fields are ignored for forward compatibility.
- Unknown frame types from the agent are silently ignored for forward compatibility.
- `id` is opaque to the agent; it must be echoed exactly in the matching `result`.
- Frames that fail JSON decoding are silently dropped. The connection is not closed because a single malformed frame should not terminate an otherwise healthy session.

## How (High Level)

### Supervisor Topology

The Application supervisor gains two new children alongside Bandit:

1. **ExCodeRemote.Agent.Registry** — a standard Registry with unique keys.
2. **ExCodeRemote.Agent.Supervisor** — a DynamicSupervisor that owns all Connection processes.

Both must be started before Bandit in the Application supervision tree, because Bandit may accept agent connections immediately on boot and those connections need the Registry and DynamicSupervisor to already be available.

Each Connection process is started dynamically under the DynamicSupervisor only after authentication succeeds in the WebSock handler. A connection that fails auth never becomes a supervised process.

### AUTH_TOKEN Configuration

The `AUTH_TOKEN` environment variable must be set at boot. If it is absent, empty, or contains only whitespace, the application should fail to start with a clear error message, since running without authentication would allow any client to connect and execute commands on agents.

The validation must happen early in the Application start callback, before any children are started. This ensures the failure is loud and immediate rather than manifesting as a subtle runtime error when the first agent tries to connect.

The resolved token value should be stored in application config so that the router can access it without re-reading the environment on every connection attempt.

### Connection GenServer

The Connection GenServer holds the machine name, a reference to the socket handler process (its PID), a connected-at timestamp (wall-clock UTC for observability), and a pending commands map (empty until SPEC-4 populates it). It uses `restart: :temporary` because a crashed connection should not auto-restart — the agent reconnects on its own with full protocol state.

The Connection registers itself in the Agent.Registry under the machine name on start, using the standard via-tuple naming convention so that deregistration is automatic when the process terminates.

The Connection must handle the `dispatch` call even in this spec. When it receives a dispatch call, it returns `{:error, :not_implemented}`. This ensures the call path from the facade through the Registry lookup to the Connection GenServer is exercised end-to-end, which SPEC-4 will replace with the real implementation.

#### Process Relationship: Connection and Socket

The Connection GenServer and the Socket (WebSock handler) are two separate processes that must be aware of each other's lifecycle:

- The Socket process is created by Bandit when the HTTP connection upgrades to WebSocket. The Socket is the process that owns the raw TCP connection.
- The Connection GenServer is started under the DynamicSupervisor during WebSock init, after auth succeeds. The Socket passes its own PID to the Connection on start so the Connection can send outbound frames.
- The Connection monitors the Socket process. If the Socket dies (TCP disconnect, crash), the Connection receives a DOWN message and terminates itself, which deregisters the machine name from the Registry.
- The Socket monitors the Connection process. If the Connection dies (crash, explicit stop during reconnect), the Socket receives a DOWN message and closes the WebSocket cleanly.

This bidirectional monitoring ensures that neither process becomes orphaned. There is no process link between them — monitors are used so that a crash in one does not propagate as an exit signal to the other, allowing each side to clean up intentionally.

#### Socket Init Failure

If the Socket's init callback succeeds at auth but fails to start the Connection GenServer (for example, because the DynamicSupervisor is unavailable or start_child returns an error), the Socket must close the WebSocket connection with code 1011 (internal error). This is a server-side failure, not a client auth failure, and the close code must reflect that. The failure should be logged at error level.

### WebSock Handler (Socket)

The Socket module implements the WebSock behaviour and is the process that owns the raw TCP connection. It receives raw JSON frames, decodes them, and routes them:

- `result` frames are forwarded to the Connection GenServer via a cast.
- `ping` frames get an immediate `pong` reply.
- `pong` frames are forwarded to the Connection GenServer via a cast (for future use by keepalive timeout logic), or ignored if the Connection does not yet handle them.
- Unknown frame types are silently ignored for forward compatibility.
- Frames that fail JSON decoding are silently dropped and logged at debug level.

The Connection GenServer sends outbound frames (like `execute` and `ping`) to the Socket via process messages, which the Socket encodes and pushes down the wire.

If the Socket receives a frame after its Connection GenServer has already terminated (a narrow race window during teardown), it must not crash. The cast to a dead PID is naturally a no-op, but the Socket should treat the missing Connection as a signal to close.

### Router Upgrade

The `/ws/agent` route in the router extracts `token` and `machine` from query params. The route itself performs the token comparison using constant-time comparison (such as the secure compare function from Plug.Crypto). If auth fails, the route rejects the upgrade by sending an appropriate HTTP response before the WebSocket handshake completes — no WebSocket close frame is sent because the connection was never upgraded.

However, if auth succeeds and the machine param is valid, the route upgrades to WebSocket via WebSockAdapter, passing the validated machine name to the Socket as init args. The Socket's init callback then starts the Connection GenServer under the DynamicSupervisor.

**Important clarification on close codes vs HTTP rejections:** The close codes `4002` and `4003` listed in the protocol section are the logical rejection reasons. Whether these are delivered as WebSocket close frames or as HTTP error responses before upgrade depends on when in the handshake the rejection occurs. If the router rejects before upgrade (the expected path), these manifest as HTTP 403/400 responses. If for any reason auth validation happens post-upgrade (in the WebSock init callback), they are sent as WebSocket close frames. The implementation should prefer pre-upgrade rejection so that unauthorized clients never complete the WebSocket handshake.

**HTTP rejection responses:** When auth fails before upgrade, the router should return HTTP 403 for a bad or missing token and HTTP 400 for a missing or empty machine name. The response body should be a JSON object with an `error` field containing the same reason string as the corresponding close code (for example, `forbidden` or `missing_machine`) so that clients get a consistent error identifier regardless of the rejection mechanism.

### Reconnect Semantics

When an agent with the same machine name reconnects, the old Connection GenServer is stopped (which closes its socket) before the new one is registered. This matches the Python server's "last write wins" behavior and avoids orphaned pending state.

The reconnect sequence must be: look up existing Connection by machine name, stop it synchronously (wait for termination confirmation), then start and register the new Connection. This ordering prevents a window where two Connections for the same machine coexist.

**Concurrent reconnect race:** If two connections arrive simultaneously with the same machine name, the Registry's unique-key constraint is the final arbiter. The implementation should serialize the stop-and-register sequence within `Agent.start_connection/2` to prevent the race. The recommended approach is to perform the lookup, stop, and start within a single synchronous flow so that concurrent callers are naturally serialized by the Registry's unique-key enforcement. If registration fails because another process registered between the stop and the start, the implementation should retry the full stop-and-register sequence once. If the retry also fails, it should return an error rather than looping indefinitely.

### Graceful Shutdown

When the application shuts down, the DynamicSupervisor terminates all Connection children. Each Connection, upon receiving its shutdown signal, should instruct its Socket to close the WebSocket with code 1001 (going away) before terminating. This gives agents a clean signal that the server is intentionally going away, as opposed to a crash or network failure.

**Shutdown ordering caveat:** Because the Registry and DynamicSupervisor are started before Bandit in the supervision tree, they are shut down after Bandit during application termination (children shut down in reverse start order). This means Bandit will terminate its acceptors and socket processes first, which will kill Socket processes and trigger monitor-based teardown of Connection processes before the DynamicSupervisor receives its shutdown signal. In practice, this means the 1001 close code may not be delivered reliably during application shutdown, because the Socket processes are already dead by the time Connections attempt to send the close frame. The Connection's terminate callback must handle the case where the Socket is already dead — it should attempt to send the 1001 close instruction but not fail if the Socket PID is no longer alive. The agent should treat any unclean socket closure from the server as a signal to reconnect, whether or not it receives a 1001 frame.

### Logging

Connection lifecycle events should be logged at info level: successful connection (including machine name), disconnection (including machine name and reason — clean close, socket crash, or Connection crash), and reconnection replacement (including machine name). Auth failures should be logged at warning level with the rejection reason but without the submitted token value, to support intrusion detection without leaking credentials. DynamicSupervisor start failures during Socket init should be logged at error level.

### Public API

The `ExCodeRemote.Agent` module provides a thin facade that hides the Registry and DynamicSupervisor details:

- `connected?(machine)` — returns true if a connection is registered under the given name.
- `list()` — returns a list of all connected machine names.
- `start_connection(machine, socket_pid)` — starts a new Connection under the supervisor, with the Connection monitoring the given Socket process. Handles the reconnect-replacement flow if a Connection for this machine already exists. Returns `{:ok, pid}` on success, where pid is the new Connection GenServer. Returns `{:error, reason}` if the Connection could not be started (DynamicSupervisor failure, repeated registration conflict).
- `stop_connection(machine)` — stops an existing Connection. Returns `{:ok, :stopped}` if a connection existed, or `{:error, :not_connected}` if none was registered.
- `dispatch(machine, command, timeout)` — looks up the Connection in the Registry and delegates the call to it. The `command` argument is a map containing the fields that will be sent in the `execute` frame (such as `command_type`, `command`, `path`, `content`, `working_dir`). The structure of this map is defined by SPEC-4; in this spec the Connection ignores the contents and returns `{:error, :not_implemented}`. The `timeout` argument specifies how long the caller is willing to wait for a result (also defined fully in SPEC-4). Returns `{:error, :not_connected}` if no connection is registered for the given machine name. The lookup-then-call must handle the race where a Connection deregisters between the lookup and the call; in that case, it should return `{:error, :not_connected}` rather than crashing.

The Agent facade is the stable API boundary that every downstream spec builds against. SPEC-4 replaces the dispatch stub, SPEC-5 calls dispatch from MCP tool handlers, SPEC-6 observes connection events, and SPEC-7 attaches telemetry. The interface defined here must be treated as a contract — changes to function signatures or return value shapes after this spec ships require updating all downstream specs.

## How to Evaluate

### Success Criteria

- [ ] Agent.Registry and Agent.Supervisor are started by the application supervisor, both before Bandit
- [ ] The application refuses to start if AUTH_TOKEN is absent, empty, or whitespace-only, with a clear error message
- [ ] A WebSocket client can connect to `/ws/agent?token=…&machine=…` and the connection is accepted
- [ ] Missing `token` or wrong `token` results in rejection (HTTP 403 or close code `4003`)
- [ ] Missing or empty `machine` results in rejection (HTTP 400 or close code `4002`)
- [ ] `Agent.connected?("name")` returns `true` while the agent is connected, `false` after disconnect
- [ ] `Agent.list()` reflects current connections accurately — a name appears exactly once while connected and disappears immediately after disconnect
- [ ] Reconnect with the same machine name replaces the old connection cleanly (old GenServer stops, new one registered, `Agent.list()` contains the name exactly once throughout)
- [ ] `Agent.dispatch/3` returns `{:error, :not_connected}` for unknown machines and `{:error, :not_implemented}` for known ones
- [ ] Agent-sent `ping` produces a server `pong`; server-sent `ping` expects agent `pong`
- [ ] Unknown frame types from the agent are silently ignored — the connection remains open and functional
- [ ] Protocol section above matches the existing Python agent's behavior (verified by running the Python agent against the new server)
- [ ] If the Socket process dies, the Connection GenServer terminates and deregisters from the Registry
- [ ] If the Connection GenServer dies, the Socket process closes the WebSocket cleanly
- [ ] Malformed JSON frames do not crash the connection
- [ ] Binary frames result in the connection being closed with code 1003
- [ ] Connection lifecycle events (connect, disconnect, reconnect replacement) are logged at info level
- [ ] Auth failures are logged at warning level without leaking the submitted token
- [ ] If Connection GenServer startup fails during Socket init, the WebSocket closes with code 1011

### Primary Validation: Real Agent Compatibility

The most important success signal for this spec is not in the automated tests — it is the manual validation that the existing Python agent can connect to the new server with only a URL change and behave identically to how it behaves against the Python server. This is the entire value proposition of freezing the wire protocol. If the Python agent cannot connect, authenticate, exchange pings, and disconnect cleanly against this implementation, nothing else in this spec matters.

The implementer should run this validation early and often, not just as a final check. The Python agent at `~/code/code-remote/agent/agent.py` is the ground truth for what the wire protocol actually looks like in practice. Any discrepancy between the protocol tables above and the agent's actual behavior should be resolved in favor of the agent — the tables describe the agent, not the other way around.

### Tests

Tests should be included with the implementation changes:

- **Connection GenServer unit tests** — test the GenServer directly without a real socket: starts and registers under the machine name (verified via Registry lookup), stops and deregisters (verified via Registry lookup returning empty), `handle_result` with unknown ID is a no-op (no crash, no side effects), terminates when its monitored socket process exits (simulate by starting a dummy process, passing it as the socket PID, then killing it). Also verify that the GenServer's initial state has an empty pending commands map and a connected-at timestamp.
- **WebSocket integration tests** — use a real WebSocket client (such as Mint.WebSocket or the :websocket_client library) against a Bandit instance on an ephemeral port: happy-path connect and disconnect, auth rejection with bad token gets HTTP 403 or close code 4003, missing machine gets HTTP 400 or close code 4002, ping/pong round-trip (send a ping frame and assert a pong frame is received), malformed JSON frame does not kill the connection (send garbage text then send a valid ping and confirm pong still comes back), binary frame results in close code 1003.
- **Unknown frame type test** — send a JSON frame with an unrecognized `type` value and verify the connection remains open and functional (for example, send an unknown type frame, then send a ping and confirm a pong comes back).
- **Reconnect test** — two connections in sequence with the same machine name; the second supplants the first, and `Agent.list/0` contains the name exactly once throughout. The old Connection's socket is closed before the new one completes setup. Verify by asserting the old socket receives a close frame or its process exits before the new Connection is registered.
- **Concurrent reconnect test** — two connections arriving simultaneously with the same machine name. Only one should survive, the other's socket should be closed, and `Agent.list/0` should contain exactly one entry. This can be tested by starting two connections in parallel tasks and asserting the final state. Because true simultaneity cannot be guaranteed in a test, the assertion should focus on the invariant (exactly one connection survives, Registry has exactly one entry) rather than controlling exact timing.
- **Public API tests** — `Agent.dispatch` against unknown machine returns `{:error, :not_connected}`, against connected machine returns `{:error, :not_implemented}`. `Agent.connected?/1` returns the correct boolean for connected and unconnected names. `Agent.list/0` returns an empty list with no connections, and a correct list after connections are established.
- **Crash isolation test** — killing the Socket process causes the Connection to terminate and deregister (verified by checking the Registry is empty after a short delay); killing the Connection process causes the Socket to close the WebSocket (verified by asserting the WebSocket client receives a close frame). Both directions must be tested independently.
- **AUTH_TOKEN validation test** — the application refuses to start when AUTH_TOKEN is unset, empty, or whitespace-only. This can be tested by temporarily overriding the application env and asserting that Application.start returns an error.
- **Facade race condition test** — call `Agent.dispatch/3` for a machine that disconnects between the Registry lookup and the GenServer call. The function should return `{:error, :not_connected}` rather than crashing. This can be simulated by connecting a machine, capturing its Connection PID, stopping the Connection directly (bypassing the facade), and then calling dispatch.
- **Graceful shutdown test** — verify that when the Connection GenServer receives a shutdown signal, it attempts to instruct its Socket to send a close frame with code 1001. This can be tested at the unit level by calling the Connection's terminate callback with a live dummy Socket process and asserting the Socket receives the close instruction. Note that full end-to-end graceful shutdown (where the application supervisor tears down all children) may not reliably deliver the 1001 frame due to the shutdown ordering described in the Graceful Shutdown section; the test should verify the Connection's intent to send 1001, not guarantee delivery.

### Validation

- `mix test` passes
- Manual: run `~/code/code-remote/agent/agent.py` against `ws://localhost:4000/ws/agent`, confirm `Agent.list()` shows it, confirm disconnect is clean on Ctrl-C
- `mix compile --warnings-as-errors` clean

## Notes

- WebSock / WebSockAdapter is the right abstraction here: it's what Bandit and Phoenix both build on, it keeps the socket process's mailbox in the caller's hands, and it has clean integration with Plug upgrades.
- The split between Socket (raw frames) and Connection (state + lifecycle) is deliberate. It means the Connection GenServer can be tested with plain GenServer calls, without needing a real socket, which makes SPEC-4's tests dramatically simpler.
- Reconnect semantics ("last write wins") match the Python server, but they're worth calling out because they're the most common source of flaky multi-connection bugs.
- The pre-upgrade auth check is important for security posture: unauthorized clients should not complete the WebSocket handshake at all, avoiding resource consumption from unauthenticated connections.
- The Agent facade module is the stable API boundary that SPEC-4 and SPEC-5 will build against. Even though the dispatch path is stubbed, the full call chain from facade through Registry lookup to Connection GenServer should be exercised in this spec so that SPEC-4 only needs to replace the stub, not rewire the plumbing.
- The application-level ping/pong mechanism defined here does not include scheduled keepalive or liveness timeout behavior. The Python agent currently manages its own reconnection logic, so passive ping/pong handling is sufficient for the initial implementation. If server-initiated liveness detection is needed, it should be specified in a follow-up.

## Observations

- [decision] One GenServer per agent, registered by machine name — canonical BEAM pattern, validated by Tidewave
- [decision] `restart: :temporary` on Connection — crashes mean "agent is gone," do not try to resurrect a process with no socket
- [decision] Split Socket (WebSock handler) from Connection (GenServer) — lets us test state/lifecycle without a real socket
- [decision] Bidirectional monitoring between Socket and Connection — ensures neither process becomes orphaned after a crash, without using links that would propagate exit signals
- [decision] Reconnect replaces, does not reject — matches Python server; avoids stale-entry bugs
- [decision] Reconnect replacement is synchronous — old Connection must be confirmed stopped before new one registers, to prevent coexistence window
- [decision] `dispatch/3` stubbed to `{:error, :not_implemented}` — the interface lands now so callers can be written against it in SPEC-4 and SPEC-5
- [decision] `dispatch/3` routes through the Connection GenServer even while stubbed — exercises the full call chain so SPEC-4 only replaces the stub logic, not the routing
- [decision] Auth before upgrade — reject unauthorized clients at the HTTP layer, not after WebSocket handshake
- [decision] Graceful shutdown sends close code 1001 — gives agents a clean signal that the server is going away intentionally, though delivery is best-effort due to supervision tree shutdown ordering
- [decision] Wire protocol frozen to match the existing Python agent exactly — this is the migration enabler; it means zero agent-side changes and instant rollback during the SPEC-8 bake-off
- [constraint] Wire protocol is frozen — the Python agent must not require changes to talk to this server
- [constraint] `AUTH_TOKEN` is required at boot — the application must not start without it, validated before any children are started
- [constraint] Registry and DynamicSupervisor must start before Bandit in the supervision tree
- [pattern] Auth happens before the GenServer is started, so unauthorized traffic never touches supervised state
- [pattern] The Agent facade is the only public API — all callers go through it, never directly to Registry or DynamicSupervisor
- [risk] Concurrent reconnects with the same machine name can race on Registry registration — implementation must serialize the stop-and-register sequence and retry once on conflict
- [risk] dispatch/3 has a TOCTOU race between Registry lookup and GenServer call — must handle the case where Connection deregisters between the two steps
- [risk] Supervision tree shutdown ordering means Bandit terminates Socket processes before the DynamicSupervisor terminates Connection processes — graceful 1001 delivery is best-effort, and agents must tolerate unclean disconnects
- [risk] Keepalive deferral means stale connections can accumulate in the Registry until the agent-side reconnect logic fires — acceptable for the bake-off but must be addressed before the Python server is retired in SPEC-8
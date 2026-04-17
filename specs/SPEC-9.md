---
title: 'SPEC-9: Tailscale Private Network Enforcement'
type: spec
permalink: specs/spec-9-tailscale-private-network-enforcement
tags:
- security
- tailscale
- network
- plug
status: implemented
---

# SPEC-9: Tailscale Private Network Enforcement

## Why

The Python server (the existing implementation that this Elixir project is replacing) restricts agent WebSocket connections to Tailscale CGNAT IPs (`100.64.0.0/10`) so that even if the shared `AUTH_TOKEN` (established in SPEC-3 as the agent authentication mechanism) leaks, an attacker cannot register as an agent without also being on the owner's tailnet. This is a defense-in-depth layer on top of token auth, and it's worth keeping.

This is the security boundary that separates "someone found the token" from "someone can actually impersonate a machine on the network." Without it, a leaked token is a full compromise — any internet-connected attacker can register agents and receive commands intended for real machines. With it, exploitation requires both the token and physical or administrative access to the tailnet, which is a fundamentally different threat class.

This spec is deliberately the last one in the sequence because:

1. It is strictly additive — the server functions without it.
2. Landing it before the core is stable means debugging with an extra failure axis.
3. The Tailscale setup on Fly.io is fiddly and has its own rollout risk.

With the core proven stable after SPEC-8's bake, this spec adds the network check and the Tailscale daemon sidecar.

## What

**Dependencies:** SPEC-8 (deployment, Dockerfile) must be complete. This spec modifies the Dockerfile from SPEC-8 and adds a new Plug to the router from SPEC-3.

**In scope:**

- `ExCodeRemote.Plugs.PrivateNetwork` — a Plug that checks the effective client IP against an allow-list
- IP extraction: prefer the `fly-client-ip` header (set by Fly's proxy and not spoofable by clients); fall back to rightmost IP in `x-forwarded-for`; fall back to `conn.remote_ip` when no proxy headers are present (see the "Header Trust and IP Spoofing" section under Risks for the full rationale)
- Tailscale CGNAT range (`100.64.0.0/10`) allowed by default
- Loopback addresses (`127.0.0.1`, `::1`) allowed unconditionally (dev, and potentially Tailscale userspace networking — see Risks)
- Env-gated: `REQUIRE_PRIVATE_NETWORK=true` by default in prod; `false` in dev and test
- Plug applied **only** to `/ws/agent`, never to the MCP SSE endpoint (Claude.ai needs public access)
- Logging of denied connections at warn level, including the offending IP and the route, for debugging and audit
- Tailscale daemon added to the SPEC-8 Dockerfile, started before the Elixir release via an entrypoint script
- `TAILSCALE_AUTHKEY` Fly secret, following the Python server's existing pattern

**Out of scope:**

- Per-agent ACLs (the current model is "anyone on the tailnet with the token can connect as any machine name")
- IPv6 Tailscale ranges (Fly.io + Tailscale uses IPv4 CGNAT)
- Alternative private network backends (Fly WireGuard, mesh VPNs, etc.)
- Automatic auth key rotation (90-day max, manual rotation)
- Agent-side configuration changes (updating agent RELAY_URL to use the Tailscale IP is an operational step documented in this spec for reference, but it is not a deliverable of this spec)

## How (High Level)

This spec decomposes into three independent work streams that converge at integration testing. The Plug implementation and router integration can be built and unit-tested locally with no Tailscale or Fly dependency. The Dockerfile and entrypoint work is independent of application code. Deploy validation brings them together.

### Task 1: Plug Implementation

A Plug module (`ExCodeRemote.Plugs.PrivateNetwork`) that:

1. Checks whether private network enforcement is enabled via application config (sourced from `REQUIRE_PRIVATE_NETWORK` env var). If disabled, the request passes through.
2. Extracts the client IP using the strategy described in the "Header Trust and IP Spoofing" section under Risks. The preferred approach is: check for the `fly-client-ip` header first (Fly overwrites this, so it cannot be spoofed); if absent, parse `x-forwarded-for` using the rightmost IP; if no proxy headers are present, fall back to `conn.remote_ip`. The implementer must document in a code comment which approach they chose and why.
3. Checks the IP against the allow-list: loopback addresses always pass, Tailscale CGNAT range (`100.64.0.0/10`) passes, everything else is denied.
4. Denied requests get a 403 response with a JSON body (matching the error format used elsewhere in the application) and the connection is halted before the WebSocket upgrade can proceed. The plug logs every denial at warn level, including the denied IP and the requested path.

The plug **fails closed**: any parse error, missing IP, or unexpected format results in denial. The only way through is to be recognizably on the tailnet (or loopback in dev).

The CIDR check for `/10` is a simple bitmask comparison — no external dependency needed for a single range. The allowed range spans `100.64.0.0` through `100.127.255.255`. The bitmask is: the first 10 bits of the IP must match the first 10 bits of `100.64.0.0`.

**IP extraction specifics:** The plug must handle these header variations:

- **fly-client-ip present:** Use its value directly. This is the preferred path on Fly.
- **fly-client-ip absent, single x-forwarded-for IP:** Use that IP.
- **fly-client-ip absent, multiple x-forwarded-for IPs (comma-separated):** Use the rightmost IP (the one Fly appended).
- Whitespace around IPs: values may have spaces after commas; these must be trimmed.
- Empty header value: treat as absent, fall back to `conn.remote_ip`.
- Malformed IPs (not parseable as IPv4 or IPv6): deny the request (fail closed).
- Multiple `x-forwarded-for` headers: concatenate per RFC 7230 and take the rightmost IP from the combined list.
- **No proxy headers at all:** Fall back to `conn.remote_ip`. This is the expected path in dev and test environments.

**Done when:** The plug module exists, has full unit test coverage per the Tests section below, and handles all the IP extraction variations listed above.

### Task 2: Runtime Config and Router Integration

**Runtime config:** The `REQUIRE_PRIVATE_NETWORK` env var (default `"true"` in prod) is read in `runtime.exs` and stored in application config. The test config (`config/test.exs`) must set this to `false` so that existing WebSocket tests from SPEC-3 continue to pass without Tailscale IPs. The dev config (`config/dev.exs`) must also set this to `false`.

The config key should live under the application's own namespace (e.g., `config :ex_code_remote, :require_private_network`) and the plug should read it from application config at call time, not at compile time, so that the test config override works correctly.

The env var parsing must handle the string `"true"` (case-insensitive) as enabled, and any other value (including unset) as disabled in non-prod environments. In `runtime.exs` for prod, the default when the env var is unset should be `true` (enabled). This ensures the plug cannot be accidentally disabled in production by omitting the env var. To be explicit: the prod default is "enabled" and the dev/test default is "disabled," and these defaults are set in the Elixir config files for each environment, not through any runtime detection of the environment name.

**Router integration:** The plug is applied inline on the `/ws/agent` route only, before the existing auth and upgrade logic from SPEC-3. The MCP transport routes and the `/health` endpoint remain publicly accessible — Claude.ai must be able to reach MCP from the public internet, and Fly health checks must not be gated.

No other routes are affected. The plug must not be added to a pipeline or scope that could accidentally gate non-agent routes. The implementer should verify that the plug is scoped narrowly enough that future route additions do not inherit it by default.

**Verification step:** After wiring the plug into the router, run the full existing test suite to confirm no regressions. Specifically, all SPEC-3 WebSocket tests must pass without modification — the test config disables the plug, so they should be unaffected.

**Done when:** Config is wired in all three environments (prod, dev, test), the plug is mounted on the correct route only, and the full test suite passes with no changes to existing tests.

### Task 3: Dockerfile and Entrypoint Script

Modify the Dockerfile from SPEC-8: copy the Tailscale binaries (`tailscale` and `tailscaled`) from the official `tailscale/tailscale` image into the runtime stage. Pin the Tailscale image to a specific version tag (not `latest`) for build reproducibility. Record the chosen version in a comment in the Dockerfile so it can be updated deliberately.

Replace the entry command with a shell script (e.g., `entrypoint.sh`) that:

1. If `TAILSCALE_AUTHKEY` is set, starts `tailscaled` in userspace networking mode and runs `tailscale up` with the auth key and a stable hostname. The entrypoint must wait for `tailscale up` to complete and confirm a successful connection before proceeding. If `tailscale up` fails (non-zero exit code or times out after a reasonable deadline — 30 seconds is a sensible default), the entrypoint should exit non-zero so Fly treats the machine as unhealthy rather than running the server without Tailscale protection. The entrypoint should log clearly what happened: "Tailscale connected as (hostname) with IP (ip)" on success, or "Tailscale failed to start: (reason)" on failure.
2. If `TAILSCALE_AUTHKEY` is not set, skips Tailscale startup entirely and logs that it is doing so. This allows the same image to run in local or CI environments without Tailscale.
3. Runs database migrations.
4. Starts the Elixir release.

This matches the Python server's `start.sh` pattern. The `tailscale up` invocation should include the `--authkey` flag and a `--hostname` flag set to a stable identifier (e.g., the Fly app name or machine ID from the `FLY_APP_NAME` or `FLY_MACHINE_ID` env vars) so the node keeps a consistent Tailscale identity across restarts.

The entrypoint script must be executable (chmod +x) and use `exec` for the final command (starting the Elixir release) so that the release process becomes PID 1 and receives signals correctly for graceful shutdown.

**Tailscale state directory:** `tailscaled` needs a writable directory for its state. On Fly, the filesystem is ephemeral by default. The entrypoint should set `--statedir` to a path within the container (e.g., `/var/lib/tailscale`). If a Fly volume is mounted at that path, Tailscale state persists across restarts and re-authentication is not needed on every deploy. If no volume is mounted, Tailscale re-authenticates on every start using the auth key — this is the expected default behavior and is acceptable.

**Done when:** The Dockerfile builds successfully, the entrypoint script handles both the Tailscale and no-Tailscale paths, and a local `docker build` completes without errors. The entrypoint script's branching logic (Tailscale path vs. skip path, failure exit vs. success continuation) should be manually verified by reading the script and confirming it matches the specified behavior. Full runtime validation requires deploy (see Deploy Validation below).

### Tailscale Networking Mode

Fly machines may not support kernel TUN devices, so Tailscale should be started with the `--tun=userspace-networking` flag on `tailscaled`. In userspace networking mode, tailscaled proxies connections rather than creating a virtual network interface. This has an important implication for IP visibility: connections arriving via Tailscale may present `conn.remote_ip` as `127.0.0.1` (loopback) rather than the sender's Tailscale CGNAT IP, because the traffic is proxied through the local daemon.

The implementer must verify which IP `conn.remote_ip` actually contains for Tailscale connections in the Fly environment by examining the Python server's behavior or running a test deployment. If Tailscale userspace mode does present connections as loopback, then the security model relies on: (a) the Tailscale daemon only accepting connections from authenticated tailnet peers, and (b) loopback being trusted because only the Tailscale daemon and the Elixir release process run on the Fly machine. This second assumption must be verified — if Fly runs any sidecar processes (metrics agents, log shippers, or health check probes) on the same machine, those processes could theoretically reach the server via loopback and bypass the IP check. The implementer should confirm that the Fly machine does not run additional processes that could exploit loopback trust. If it does, the loopback trust model needs to be revisited.

This is acceptable — the defense-in-depth boundary is Tailscale's own peer authentication — but it must be documented and understood, not discovered in production.

**Action required before declaring this spec complete:** Deploy a test build to Fly with Tailscale enabled and log `conn.remote_ip` for an agent connection arriving over the tailnet. Record the result (CGNAT IP or loopback) in the PR description. If the answer is loopback, add a code comment on the loopback allow-list explaining why loopback is trusted in production (Tailscale userspace proxy) and not just for dev convenience.

### Secrets

`TAILSCALE_AUTHKEY` is set via `fly secrets set`. The key should be reusable (so the machine can reconnect after restarts) and has a 90-day maximum expiration. Rotation is a manual, quarterly task.

### Agent-Side Update (Operational Guidance)

This section is not a deliverable of this spec. It documents the operational steps that agent operators must take after the server-side changes are deployed.

Agents need their `RELAY_URL` pointed at the server's Tailscale IP (not the public Fly hostname). The Tailscale IP can be found in the Fly logs after deployment or via `tailscale ip -4` in a Fly SSH session. The agent's `.env` file is updated to use `ws://<tailscale-ip>:8080/ws/agent`.

The use of `ws://` (not `wss://`) is intentional here. Tailscale encrypts all traffic at the transport layer using WireGuard, so TLS on the WebSocket itself would be redundant within the tailnet.

The server must bind to an address that is reachable from both the Tailscale interface and the Fly proxy (for MCP). Binding to `0.0.0.0` on the configured port achieves this. This means the `/ws/agent` endpoint is technically reachable from the public Fly proxy as well — the PrivateNetwork plug is the enforcement point, not network-level port isolation.

**Port number:** The spec references port 8080. The implementer should confirm this matches the port configured in SPEC-8's Dockerfile and Fly config. If SPEC-8 uses a different port, use that port instead. The agent-side `RELAY_URL` must use the same port the server is actually listening on.

## Rollback

Because this spec is strictly additive, rollback is straightforward:

- **Plug only (no Tailscale deploy yet):** Set `REQUIRE_PRIVATE_NETWORK=false` as a Fly secret. The plug passes all traffic through. No code revert needed.
- **Full rollback (Tailscale causing operational issues):** Redeploy using the pre-SPEC-9 Dockerfile (without Tailscale binaries and with the original entrypoint). Set `REQUIRE_PRIVATE_NETWORK=false`. Point agents back to the public Fly hostname with `wss://`. This returns the system to its SPEC-8 state.
- **Auth key expired unexpectedly:** The server continues running on the tailnet until restarted. Generate a new reusable auth key, set it via `fly secrets set`, and redeploy. Agents may experience a brief connection interruption during the deploy.

The rollback path should be tested during deploy validation: confirm that setting `REQUIRE_PRIVATE_NETWORK=false` on a deployed instance allows non-tailnet connections to `/ws/agent`.

## Risks

### Header Trust and IP Spoofing

The `x-forwarded-for` header is client-controllable. An attacker hitting the public Fly URL can prepend a spoofed Tailscale IP to the header (e.g., `x-forwarded-for: 100.64.0.1`). If the plug naively takes the first (leftmost) IP, the check is bypassed entirely.

The recommended approach for IP extraction is, in priority order:

1. **Fly-Client-IP header** (preferred): Fly sets the `fly-client-ip` header to the direct connecting client's IP. This header is overwritten by Fly's proxy and cannot be spoofed by the client. This is the most robust option on Fly because it sidesteps `x-forwarded-for` parsing entirely.
2. **Rightmost IP in x-forwarded-for** (fallback): Take the last IP in the `x-forwarded-for` chain, which is the one appended by Fly's proxy — the only hop we trust. This is the correct approach for a single-proxy architecture like Fly when `fly-client-ip` is not available.
3. **conn.remote_ip** (final fallback): When no proxy headers are present (local dev, direct connections), use the connection's remote IP directly.

The implementer should verify that `fly-client-ip` is present and reliable on the Fly platform. If it is, use it as the primary source and ignore `x-forwarded-for` entirely for allow/deny decisions. If for any reason `fly-client-ip` is unavailable, fall back to the rightmost `x-forwarded-for` IP. The implementer should document in a code comment which approach they chose and why.

Whichever approach is chosen, the plug must never trust a client-supplied leftmost IP in `x-forwarded-for` as the basis for an allow decision. The test suite must include a test that verifies a spoofed `x-forwarded-for` with a Tailscale IP does not bypass denial.

### Tailscale Daemon Failure at Runtime

If `tailscaled` crashes or loses connectivity after the Elixir release has started, the server continues running but agents on the tailnet can no longer reach it (their connections will fail at the transport level). The PrivateNetwork plug remains active and continues to enforce on any connections that do arrive. No special crash-handling logic is needed in the Elixir app — the failure mode is "agents can't connect," not "unauthorized access is allowed." However, Fly health checks should still pass (they hit the public interface), so a crashed tailscaled will not trigger an automatic machine restart. Monitoring Tailscale connectivity is an operational concern, not an application concern. Operators should be aware that agent connectivity loss with healthy Fly health checks may indicate a tailscaled failure, and can diagnose via `fly ssh console` and checking the tailscaled process.

### Auth Key Expiration

The Tailscale auth key has a hard 90-day maximum lifetime. When it expires, the machine can no longer re-authenticate with Tailscale after a restart. The machine will continue to function on the tailnet until it is restarted or the Tailscale session expires. There is no in-app signal for this — it will manifest as a failed `tailscale up` on the next deploy or machine restart. Operators must rotate the key before expiration. Setting a calendar reminder at key creation time is the minimum viable approach.

### Silent Tailscale Failures

Two failure modes in this spec — tailscaled crash and auth key expiration — share a common characteristic: they are invisible to the standard health check and monitoring path. Fly sees a healthy machine, but agents cannot connect. This is acceptable for an initial deployment where the operator is close to the system and will notice agent disconnections quickly. However, if the number of agent operators grows or the system becomes more critical, a lightweight liveness signal for the Tailscale connection (for example, a `/health/tailscale` endpoint that checks whether `tailscaled` is running and the node has an active tailnet IP) should be considered as a follow-up. This is not in scope for this spec, but the operator should be aware that Tailscale health is a blind spot in the current monitoring model.

### 403 Response Body on WebSocket Upgrade Path

The `/ws/agent` route handles WebSocket upgrade requests. When the plug denies a request, it sends a 403 before the upgrade occurs — this is a normal HTTP response. However, WebSocket client libraries may not surface the 403 body clearly. The 403 response should include a brief JSON body (e.g., containing a reason field like "private network required") so that curl-based debugging is straightforward, but the agent's reconnection logic (from SPEC-3) should not need modification — it already handles connection failures.

## How to Evaluate

### Success Criteria

The primary outcome of this spec is that a leaked AUTH_TOKEN alone is no longer sufficient to impersonate an agent — the attacker must also have tailnet access. The criteria below verify that outcome and the operational integrity of the implementation.

- [ ] The PrivateNetwork plug is applied to `/ws/agent` only — not to MCP routes, `/health`, or any other endpoint
- [ ] MCP endpoint remains reachable from the public internet
- [ ] `/health` remains reachable from the public internet (Fly health checks)
- [ ] With `REQUIRE_PRIVATE_NETWORK=true`, a request to `/ws/agent` from a non-Tailscale IP returns `403`
- [ ] With `REQUIRE_PRIVATE_NETWORK=true`, a request from a Tailscale IP (`100.64.x.x`) is allowed
- [ ] With `REQUIRE_PRIVATE_NETWORK=false`, all IPs are allowed
- [ ] Loopback IPs are always allowed regardless of setting
- [ ] A spoofed `x-forwarded-for` header containing a Tailscale IP does not bypass the check when the actual client is not on the tailnet
- [ ] Denied connections are logged at warn level with the offending IP
- [ ] Tailscale daemon starts successfully in the Fly deployment
- [ ] Agent connects to the server's Tailscale IP and functions end-to-end
- [ ] Leaking `AUTH_TOKEN` does not allow a non-tailnet attacker to register as an agent
- [ ] Existing SPEC-3 WebSocket tests pass without modification (test config has `REQUIRE_PRIVATE_NETWORK=false`)
- [ ] If `TAILSCALE_AUTHKEY` is not set, the entrypoint skips Tailscale and starts the release normally
- [ ] If `tailscale up` fails, the entrypoint exits non-zero (Fly marks machine unhealthy)
- [ ] The entrypoint uses `exec` for the final command so the Elixir release is PID 1
- [ ] `conn.remote_ip` behavior for Tailscale userspace connections has been verified and documented
- [ ] The IP extraction strategy is documented in a code comment on the plug, explaining which header source is used and why
- [ ] The rollback path has been verified: setting `REQUIRE_PRIVATE_NETWORK=false` on a deployed instance allows non-tailnet agent connections

### Tests

Tests should be included with the implementation changes:

- **CIDR boundary tests**: `100.64.0.0` allowed (base of range), `100.64.0.1` allowed, `100.127.255.255` allowed (upper edge of /10), `100.128.0.0` denied (just outside /10), `100.63.255.255` denied (just below the range), `8.8.8.8` denied, `192.168.1.1` denied (private but not Tailscale).
- **Loopback always allowed**: `127.0.0.1` and `::1` pass regardless of the `REQUIRE_PRIVATE_NETWORK` setting.
- **fly-client-ip header**: If the chosen strategy uses `fly-client-ip`, test that its value is used when present, and that `x-forwarded-for` is ignored when `fly-client-ip` is available.
- **x-forwarded-for parsing**: the correct IP from the header is used per the chosen trust strategy; malformed header (e.g., `x-forwarded-for: not-an-ip`) results in denial (fail closed); empty header value falls back to `conn.remote_ip`.
- **x-forwarded-for with multiple IPs**: a header with a Tailscale IP in the leftmost position and a public IP in the rightmost position uses the rightmost IP, not the leftmost.
- **x-forwarded-for spoofing**: a request with a spoofed Tailscale IP in the leftmost position of `x-forwarded-for` but a public IP as the actual connecting client (rightmost position or `fly-client-ip`) is denied. This test is critical — it validates the header trust strategy.
- **Direct connection fallback**: when no proxy headers (`fly-client-ip` or `x-forwarded-for`) are present, `conn.remote_ip` is used.
- **Feature gate**: with `REQUIRE_PRIVATE_NETWORK=false`, all IPs are allowed (including public IPs that would normally be denied).
- **Router integration**: with the plug active, a non-Tailscale IP on `/ws/agent` returns 403 before WebSocket upgrade. A request to the MCP endpoint is not gated, regardless of client IP. A request to `/health` is not gated, regardless of client IP.
- **Logging**: denied requests produce a warn-level log entry containing the denied IP and the requested path.
- **403 response format**: denied requests return a JSON body with a reason field.
- **Existing tests unbroken**: all SPEC-3 WebSocket tests continue to pass.

### Deploy Validation

Deploy validation is a manual checklist performed after the code is merged and deployed. It cannot be automated in the test suite because it depends on the Fly and Tailscale environments.

- `fly deploy` with `TAILSCALE_AUTHKEY` set shows tailscaled starting in logs
- Logs show the Tailscale IP the machine registered as
- Agent on the tailnet connects successfully to the Tailscale IP
- Attempting to connect to the public Fly hostname for `/ws/agent` from outside the tailnet returns 403, but `/health` and MCP endpoints still work
- Deploy without `TAILSCALE_AUTHKEY` succeeds (Tailscale is skipped, server starts normally)
- Record the value of `conn.remote_ip` for a Tailscale connection (CGNAT IP or loopback) and document the finding
- Verify rollback path: set `REQUIRE_PRIVATE_NETWORK=false` via `fly secrets set` and confirm non-tailnet agent connections are accepted; then restore `REQUIRE_PRIVATE_NETWORK=true` and confirm enforcement resumes
- Confirm that no unexpected sidecar processes on the Fly machine can reach the server via loopback (relevant to the loopback trust model discussed in Tailscale Networking Mode)

### Validation

- Full test suite passes (including all new tests and all existing SPEC-3 tests)
- `docker build` succeeds locally
- Deploy validation checklist completed

## Notes

- The IP parsing and CIDR check are implemented manually to avoid pulling in another dependency. The one CIDR we care about is a simple bitmask predicate.
- Rotating the Tailscale auth key is a manual, quarterly task. Setting a calendar reminder is cheaper than building auto-rotation.
- If Tailscale becomes a pain point, the alternative layered defense is mutual TLS at the agent endpoint. That's a bigger spec and only worth it if the tailnet approach proves operationally unworkable.
- The Tailscale image version used in the Dockerfile should be pinned and noted in the commit message so it can be updated deliberately, not silently via a `latest` tag.

## Observations

- [decision] Plug applied only to `/ws/agent`, never to MCP or health — Claude.ai is a public service, Fly health checks must be unimpeded, the tailnet gate is for agent registration
- [decision] Manual CIDR check, no new dependency — one `/10` check is not worth a library
- [decision] Fail closed — parse errors and unknown formats deny
- [decision] Env-gated via `REQUIRE_PRIVATE_NETWORK` — prod defaults to true, dev/test default to false
- [decision] Tailscale daemon started by a shell entrypoint before the Elixir release — matches the Python server's `start.sh` pattern, no OTP-side coupling
- [decision] Entrypoint exits non-zero if tailscale up fails — fail-fast so Fly treats the machine as unhealthy, rather than running unprotected
- [decision] Shipped last because it is additive, fiddly, and the core needs to be proven first
- [decision] ws:// (not wss://) for agent connections — Tailscale provides WireGuard encryption at the transport layer
- [decision] Entrypoint uses exec for the final command — Elixir release must be PID 1 for signal handling
- [decision] Prefer fly-client-ip over x-forwarded-for parsing — Fly overwrites the header, removing the spoofing surface entirely
- [constraint] Reuses the Python server's `100.64.0.0/10` range and `TAILSCALE_AUTHKEY` secret — same tailnet, same operational story
- [constraint] Test config must disable the plug so SPEC-3 tests don't break
- [constraint] x-forwarded-for must not be naively trusted — the header is client-controllable and the plug must use fly-client-ip or the rightmost IP to avoid spoofing
- [constraint] Tailscale state directory must be writable — use a path within the container, optionally backed by a Fly volume for persistence
- [constraint] Loopback trust assumes no other processes on the Fly machine can initiate connections — this assumption must be verified during deploy validation
- [risk] Tailscale auth key expires every 90 days; rotation is manual and must be calendared
- [risk] Tailscale userspace networking may present connections as loopback — implementer must verify IP visibility in the Fly environment before relying on the CIDR check for Tailscale connections
- [risk] Tailscaled crash after startup is silent to Fly health checks — agents lose connectivity but the machine stays "healthy" from Fly's perspective
- [risk] Silent Tailscale failures (both daemon crash and key expiration) are invisible to standard monitoring — acceptable for initial deployment, but a monitoring blind spot to revisit if operational scale grows
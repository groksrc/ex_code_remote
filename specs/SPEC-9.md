---
title: 'SPEC-9: Tailscale Private Network Enforcement'
type: spec
permalink: specs/spec-9-tailscale-private-network-enforcement
tags:
- security
- tailscale
- network
- plug
---

# SPEC-9: Tailscale Private Network Enforcement

## Why

The Python server restricts agent WebSocket connections to Tailscale CGNAT IPs (`100.64.0.0/10`) so that even if the shared `AUTH_TOKEN` leaks, an attacker cannot register as an agent without also being on the owner's tailnet. This is a defense-in-depth layer on top of token auth, and it's worth keeping.

This spec is deliberately the last one in the sequence because:

1. It is strictly additive — the server functions without it.
2. Landing it before the core is stable means debugging with an extra failure axis.
3. The Tailscale setup on Fly.io is fiddly and has its own rollout risk.

With the core proven stable after SPEC-8's bake, this spec adds the network check and the Tailscale daemon sidecar.

## What

**In scope:**

- `ExCodeRemote.Plugs.PrivateNetwork` — a Plug that checks the effective client IP against an allow-list
- IP extraction from `x-forwarded-for` header, falling back to the direct connection IP
- Tailscale CGNAT range (`100.64.0.0/10`) allowed by default
- Loopback addresses (`127.0.0.1`, `::1`) allowed unconditionally (dev)
- Env-gated: `REQUIRE_PRIVATE_NETWORK=true` by default; `false` disables the check entirely
- Plug applied **only** to `/ws/agent`, never to the MCP SSE endpoint (Claude.ai needs public access)
- Tailscale daemon in the Dockerfile, started before the Elixir release via an entrypoint script
- `TAILSCALE_AUTHKEY` Fly secret, following the Python server's existing pattern

**Out of scope:**

- Per-agent ACLs (the current model is "anyone on the tailnet with the token can connect as any machine name")
- IPv6 Tailscale ranges (Fly.io + Tailscale uses IPv4 CGNAT)
- Alternative private network backends (Fly WireGuard, mesh VPNs, etc.)
- Automatic auth key rotation (90-day max, manual rotation)

## How (High Level)

### Plug Implementation

A Plug module that:

1. Checks whether private network enforcement is enabled via application config (sourced from `REQUIRE_PRIVATE_NETWORK` env var). If disabled, the request passes through.
2. Extracts the client IP: first from the `x-forwarded-for` header (taking the first IP in the chain, which is the original client behind Fly's proxy), falling back to `conn.remote_ip`.
3. Checks the IP against the allow-list: loopback addresses always pass, Tailscale CGNAT range (`100.64.0.0/10`) passes, everything else is denied.
4. Denied requests get a 403 response and the connection is halted before the WebSocket upgrade can proceed.

The plug **fails closed**: any parse error, missing IP, or unexpected format results in denial. The only way through is to be recognizably on the tailnet (or loopback in dev).

The CIDR check for `/10` is a simple bitmask comparison — no external dependency needed for a single range.

### Router Integration

The plug is applied inline on the `/ws/agent` route only, before the existing auth and upgrade logic from SPEC-3. The MCP transport routes remain publicly accessible — Claude.ai must be able to reach them from the public internet.

### Runtime Config

The `REQUIRE_PRIVATE_NETWORK` env var (default `"true"`) is read in `runtime.exs` and stored in application config.

### Dockerfile Changes

The runtime stage of the Dockerfile gains the Tailscale binaries (copied from the official `tailscale/tailscale` image). The entry command becomes a shell script that:

1. If `TAILSCALE_AUTHKEY` is set, starts `tailscaled` in the background and runs `tailscale up` with the auth key.
2. Runs database migrations.
3. Starts the Elixir release.

This matches the Python server's `start.sh` pattern.

### Secrets

`TAILSCALE_AUTHKEY` is set via `fly secrets set`. The key should be reusable (so the machine can reconnect after restarts) and has a 90-day maximum expiration. Rotation is a manual, quarterly task.

### Agent-Side Update

Agents need their `RELAY_URL` pointed at the server's Tailscale IP (not the public Fly hostname). The Tailscale IP can be found in the Fly logs after deployment. The agent's `.env` file is updated to use `ws://<tailscale-ip>:8080/ws/agent`.

## How to Evaluate

### Success Criteria

- [ ] The PrivateNetwork plug is applied to `/ws/agent` only
- [ ] MCP endpoint remains reachable from the public internet
- [ ] With `REQUIRE_PRIVATE_NETWORK=true`, a request to `/ws/agent` from a non-Tailscale IP returns `403`
- [ ] With `REQUIRE_PRIVATE_NETWORK=true`, a request from a Tailscale IP (`100.64.x.x`) is allowed
- [ ] With `REQUIRE_PRIVATE_NETWORK=false`, all IPs are allowed
- [ ] Loopback IPs are always allowed regardless of setting
- [ ] Tailscale daemon starts successfully in the Fly deployment
- [ ] Agent connects to the server's Tailscale IP and functions end-to-end
- [ ] Leaking `AUTH_TOKEN` does not allow a non-tailnet attacker to register as an agent

### Tests

Tests should be included with the implementation changes:

- **CIDR boundary tests**: `100.64.0.1` allowed, `100.127.255.255` allowed (upper edge of /10), `100.128.0.0` denied (just outside /10), `8.8.8.8` denied.
- **Loopback always allowed**: `127.0.0.1` and `::1` pass regardless of setting.
- **x-forwarded-for parsing**: first IP in a multi-IP chain is used; malformed header results in denial (fail closed).
- **Direct connection fallback**: when no `x-forwarded-for` is present, `conn.remote_ip` is used.
- **Feature gate**: with `REQUIRE_PRIVATE_NETWORK=false`, all IPs are allowed.
- **Router integration**: with the plug active, a non-Tailscale `x-forwarded-for` on `/ws/agent` returns 403 before WebSocket upgrade. A request to the MCP endpoint is not gated, regardless of client IP.

Deploy validation:

- `fly deploy` with `TAILSCALE_AUTHKEY` set shows tailscaled starting in logs
- Logs show the Tailscale IP the machine registered as
- Agent on the tailnet connects successfully to the Tailscale IP
- Attempting to connect to the public Fly hostname for `/ws/agent` from outside the tailnet returns 403, but `/health` still works

### Validation

- `mix test` passes
- Deploy validation checklist completed

## Notes

- The IP parsing and CIDR check are implemented manually to avoid pulling in another dependency. The one CIDR we care about is a simple bitmask predicate.
- Rotating the Tailscale auth key is a manual, quarterly task. Setting a calendar reminder is cheaper than building auto-rotation.
- If Tailscale becomes a pain point, the alternative layered defense is mutual TLS at the agent endpoint. That's a bigger spec and only worth it if the tailnet approach proves operationally unworkable.

## Observations

- [decision] Plug applied only to `/ws/agent`, never to MCP — Claude.ai is a public service, the tailnet gate is for agent registration
- [decision] Manual CIDR check, no new dependency — one `/10` check is not worth a library
- [decision] Fail closed — parse errors and unknown formats deny
- [decision] Env-gated via `REQUIRE_PRIVATE_NETWORK` — lets dev run without Tailscale and prod run with it
- [decision] Tailscale daemon started by a shell entrypoint before the Elixir release — matches the Python server's `start.sh` pattern, no OTP-side coupling
- [decision] Shipped last because it is additive, fiddly, and the core needs to be proven first
- [constraint] Reuses the Python server's `100.64.0.0/10` range and `TAILSCALE_AUTHKEY` secret — same tailnet, same operational story
- [risk] Tailscale auth key expires every 90 days; rotation is manual and must be calendared

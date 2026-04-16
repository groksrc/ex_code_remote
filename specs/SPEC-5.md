---
title: 'SPEC-5: MCP Tool Surface'
type: spec
permalink: specs/spec-5-mcp-tool-surface
tags:
- mcp
- tools
- ex_mcp
- claude
---

# SPEC-5: MCP Tool Surface

## Why

After SPEC-4, the server has a working command dispatch path but no MCP surface — nothing for Claude.ai to connect to. This spec mounts ExMCP into the Plug router, defines the five tools that the Python server exposes, and wires their handlers through `Commands.Dispatcher.run/2`. This is the spec that makes the server externally useful.

The five tools are frozen to match the Python version's existing MCP interface, so an existing Claude.ai connector configuration can point at the new server with only a URL change.

## What

**In scope:**

- `ExCodeRemote.MCP.Server` — ExMCP server definition with five tools
- Tool argument schemas, all requiring a `machine` parameter that routes to the right agent
- Tool handlers that translate MCP arguments into `Dispatcher.run/2` calls and shape the result for MCP response
- ExMCP's HttpPlug (or equivalent) mounted into `ExCodeRemote.Router` at the MCP transport paths
- `check_agent_status` tool that does not touch the dispatcher — reads from `Agent.list/0` directly
- Error translation: `{:error, :not_connected}` becomes human-readable MCP error text

**Out of scope:**

- Adding new tools beyond the five-tool surface
- Streaming responses (MCP supports them, but no tool needs them)
- Tool-level auth (MCP client auth is handled at the transport layer, not per-tool)

## Tool Surface (frozen to match Python)

Each tool takes a `machine` string as its first parameter. All tools are synchronous.

### `run_shell_command`

Arguments: `machine` (string, required), `command` (string, required), `working_dir` (string, optional — `~` is expanded by the agent), `timeout` (integer, optional, default 60 — command timeout in seconds).

Returns the stdout/stderr/exit_code triple as text.

### `read_file`

Arguments: `machine` (string, required), `path` (string, required — absolute or `~`-prefixed).

### `write_file`

Arguments: `machine` (string, required), `path` (string, required), `content` (string, required).

### `list_directory`

Arguments: `machine` (string, required), `path` (string, required).

### `check_agent_status`

No arguments. Returns the list of connected machines as a comma-separated string, or "No agents are connected."

## How (High Level)

### ExMCP Dependency

Add ExMCP (`~> 0.9.1`) to mix.exs dependencies.

### Server Module

Define `ExCodeRemote.MCP.Server` using ExMCP's server API. Register all five tools with their argument schemas and descriptions. Each command-dispatching tool handler extracts arguments, calls `Dispatcher.run/2` with the appropriate command type, and formats the result.

The ExMCP DSL may differ from what's described here — the implementer should consult the current ExMCP docs and adapt. The important part is the **shape**: five tool handlers delegating to `Dispatcher.run/2` and formatting results consistently.

### Result Formatting

A shared result formatter converts the dispatcher's result map into a text string matching the Python server's output shape:

- Output text, followed by `[stderr]: <error>` if stderr is non-empty, followed by `[exit_code: N]` if exit code is present.
- Empty results become `(no output)`.
- Errors (`:not_connected`, `:agent_disconnected`, `:timeout`) become human-readable sentences.

### Router Integration

Mount ExMCP's HttpPlug at the appropriate path in the Plug router (e.g. `forward "/mcp"` or at `/sse` + `/messages/`, depending on what ExMCP expects for the SSE transport). The MCP client URL exposed to Claude.ai will match whatever path ExMCP mounts.

## How to Evaluate

### Success Criteria

- [ ] `ExCodeRemote.MCP.Server` exports five tools with the schemas above
- [ ] `check_agent_status` returns the correct list of connected machines
- [ ] Each command-dispatching tool successfully routes to `Dispatcher.run/2` and returns a formatted result
- [ ] Error paths (`:not_connected`, `:agent_disconnected`, `:timeout`) return non-empty, readable error text
- [ ] ExMCP Plug is mounted in the router and the MCP endpoint is reachable
- [ ] Claude.ai (or any MCP client) can list tools and call them against a connected agent

### Tests

Tests should be included with the implementation changes, reusing the `FakeAgent` helper from SPEC-4:

- **Per-tool unit tests**: each of the five tools called with a connected FakeAgent returns the expected output shape.
- **Error tests**: calling a tool against an unknown machine returns the "not connected" error text.
- **`check_agent_status`**: returns "No agents are connected" with no agents, lists both names with two connected FakeAgents.
- **Result formatter**: non-empty output is trimmed, empty output becomes "(no output)", stderr and exit code are appended correctly.
- **HTTP integration test**: start Bandit on an ephemeral port, issue an MCP `tools/list` request, assert five tools present. Issue a `tools/call` for `check_agent_status`, assert response.
- **End-to-end**: issue a `tools/call` for `run_shell_command` with a connected FakeAgent, assert the result comes back correctly.

### Validation

- `mix test` passes
- Manual: point a Claude.ai connector at the MCP endpoint, list tools, run `check_agent_status`, run a shell command against a connected agent

## Notes

- The ExMCP DSL may evolve between v0.9.x releases. Pin the version and re-run tests before bumping.
- `check_agent_status` is deliberately the only tool that does not touch the dispatcher — it's a pure query over `Agent.list/0`. Keeping it in this spec matches the Python surface and avoids an artificial abstraction.
- The result formatter is deliberately simple — it mirrors what the Python version builds as a single string. Structured tool responses (separate stdout/stderr/exit_code fields) are a potential future improvement but are out of scope here.

## Observations

- [decision] Five-tool surface frozen to match Python — lets Claude.ai connector configs move over with a URL change only
- [decision] `machine` as a required argument on every dispatch-type tool — the server supports multiple agents, and the tool call must say which one
- [decision] `check_agent_status` as a tool, not a separate endpoint — MCP clients already discover tools, no reason to make this an out-of-band call
- [decision] Result formatter matches Python's string shape — avoids breaking any downstream assumptions in existing Claude.ai conversations
- [risk] ExMCP DSL API may churn before v1.0; keep the tool module small and co-locate the macro usage so a future migration is localized
- [pattern] All handlers are one-liners delegating to `Dispatcher.run/2` plus result formatting — the MCP module is a thin translation layer, not a business logic layer

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

Status: Spec-Reviewed

## Why

After SPEC-4, the server has a working command dispatch path but no MCP surface — nothing for Claude.ai to connect to. This spec mounts ExMCP into the Plug router, defines the five tools that the Python server exposes, and wires their handlers through the Agent facade's `dispatch/3`. This is the spec that makes the server externally useful.

The five tools are frozen to match the Python version's existing MCP interface, so an existing Claude.ai connector configuration can point at the new server with only a URL change.

**This is the first end-to-end validation point.** Per SPEC-1, this is the earliest milestone at which we can confirm the architecture actually solves the reliability problems — a real MCP client sending commands through the Elixir server to a real Python agent and getting results back.

**Customer impact:** Until this spec ships, every prior spec (SPEC-1 through SPEC-4) delivers zero externally visible value. This is the inflection point where the Elixir rewrite transitions from infrastructure investment to customer-facing capability. The measure of success is not whether the tools exist, but whether a Claude.ai user performing their normal workflow against the new server cannot tell that anything changed — same tools, same behavior, same results. Seamless migration is the customer promise.

## What

**Dependencies:** SPEC-4 (dispatcher) must be complete. ExMCP (`== 0.9.1`) is already in `mix.exs` from SPEC-1 but is wired into the router and supervision tree for the first time here. The Agent facade (`Agent.dispatch/3`) from SPEC-3 is the integration point — tool handlers call through the facade, never directly to the Dispatcher or Connection. The result formatter also depends on knowing the complete set of error tuples that `Agent.dispatch/3` can return — the implementer must read the Agent facade and Dispatcher modules from SPEC-3 and SPEC-4 before writing the formatter.

**Downstream dependents:** SPEC-6 (audit) records commands dispatched through this surface. SPEC-8 (deployment) is the first time this surface is exposed to real MCP clients — its cutover plan references the MCP endpoint URL, so whatever mount path is chosen here must be documented for SPEC-8. SPEC-9 (network restrictions) may layer additional transport-level protections in front of the MCP routes defined here, but explicitly leaves the MCP endpoint publicly accessible (only `/ws/agent` is gated by Tailscale).

**In scope:**

- `ExCodeRemote.MCP.Server` — ExMCP server definition with five tools
- Tool argument schemas, all requiring a `machine` parameter that routes to the right agent
- Tool handlers that translate MCP arguments into `Agent.dispatch/3` calls and shape the result for MCP response
- ExMCP's HttpPlug (or equivalent) mounted into `ExCodeRemote.Router` at the MCP transport paths
- `check_agent_status` tool that does not touch the dispatcher — reads from `Agent.list/0` directly
- Error translation: `{:error, :not_connected}` and other error tuples become human-readable MCP error text
- Adding the MCP server to the application supervision tree so it starts automatically and restarts on failure
- Input validation: required arguments must be present and of the correct type before dispatching — missing or wrong-typed arguments should return a clear error through MCP, not crash the handler
- The MCP SSE transport is unauthenticated — no token check on MCP routes. This matches the Python server and is by design: Claude.ai is a public MCP client. Agent auth (SPEC-3) and network restrictions (SPEC-9) protect the command execution path.

**Out of scope:**

- Adding new tools beyond the five-tool surface
- Streaming responses (MCP supports them, but no tool needs them)
- MCP transport auth (the transport is public; execution is gated by agent auth)
- Emitting audit events for SPEC-6 — that spec is responsible for hooking into the dispatch path via telemetry events

## Tool Surface (frozen to match Python)

Each tool takes a `machine` string as its first parameter (except `check_agent_status`). All tools are synchronous from the MCP client's perspective — the handler blocks until the agent responds or the timeout expires.

Tool descriptions in the MCP registration must be copied from or closely matched to the Python server's tool descriptions. The implementer should locate the Python server's MCP tool definitions (in the agent source at `~/code/code-remote/`) and use them as the reference text. Minor rewording is acceptable; changing the semantic meaning or omitting key details from descriptions is not, because Claude.ai uses tool descriptions to decide how to call them.

### `run_shell_command`

Arguments: `machine` (string, required), `command` (string, required), `working_dir` (string, optional — `~` is expanded by the agent), `timeout` (integer, optional, default 60 — command timeout in seconds, sent to the agent to control how long the command runs before the agent kills it).

Returns the stdout/stderr/exit_code triple as text, formatted by the result formatter described below.

Edge cases: if `timeout` is provided but is zero or negative, the handler should clamp it to a minimum of one second rather than sending an invalid value to the agent. If `command` is an empty string, the handler should still dispatch it — the agent will return an appropriate error.

### `read_file`

Arguments: `machine` (string, required), `path` (string, required — absolute or `~`-prefixed).

Returns the file contents as text. If the file is empty, returns "(no output)". If the file does not exist or cannot be read, returns the agent's error as text.

Edge case: very large file responses may be truncated by the agent — the handler does not need to impose its own size limit, but should pass through whatever the agent returns without modification beyond the standard result formatting.

### `write_file`

Arguments: `machine` (string, required), `path` (string, required), `content` (string, required).

Returns a success confirmation message that includes the path written to (matching the Python server's output format), or the agent's error as text.

### `list_directory`

Arguments: `machine` (string, required), `path` (string, required).

Returns the directory listing as text. If the directory is empty, returns "(no output)". If the path does not exist or is not a directory, returns the agent's error as text.

### `check_agent_status`

No arguments. Returns the list of connected machines as a comma-separated string (for example, "machine-a, machine-b"), a single machine name with no commas or trailing punctuation if exactly one is connected, or "No agents are connected." if none are connected.

This tool calls `Agent.list/0` directly — it never touches the dispatcher. It should return immediately with no timeout concerns.

### Input Validation (all tools)

For any tool that requires a `machine` argument: if `machine` is missing, empty, or not a string, the handler should return a clear validation error through MCP rather than dispatching. The same applies to other required arguments (`command` for `run_shell_command`, `path` for file and directory tools, `content` for `write_file`). Empty `path` and empty `content` values should be dispatched to the agent rather than rejected at the MCP layer — the agent is authoritative on whether those values are valid for the operation.

## How (High Level)

### Task Breakdown

This spec decomposes into four work units with the following dependency relationships:

1. **Result Formatter** — a standalone module with no ExMCP dependency. Can be built and fully tested against hardcoded input values independently of the other work units. This should be done first because the MCP Server module depends on it.

2. **MCP Server Module** — depends on the result formatter and on the ExMCP v0.9.1 API. Defines the five tools, their schemas, and the handler functions. Before writing this module, the implementer must read the ExMCP v0.9.1 source or documentation to determine the correct way to define a server, register tools, and handle tool calls. This investigation should happen at the start of work on this unit — if the ExMCP API does not support the expected patterns, raise the issue before writing handler code.

3. **Router Integration** — depends on the MCP Server module existing and on understanding the ExMCP transport's expected mount paths. Can be done as a separate task from the server module itself.

4. **Supervision Tree** — depends on the MCP Server module. Small change to the application supervisor's child list.

Work units two, three, and four are sequential. The result formatter (unit one) can proceed in parallel with the ExMCP API investigation that begins unit two.

### Server Module

Define `ExCodeRemote.MCP.Server` using ExMCP's server API. Register all five tools with their argument schemas and descriptions. Each command-dispatching tool handler extracts arguments, builds a command map, and calls `ExCodeRemote.Agent.dispatch(machine, command, timeout)`. The timeout for MCP tool calls should be `command.timeout + 5` seconds to match the slack convention established in SPEC-4. For tools that have no explicit timeout argument (`read_file`, `write_file`, `list_directory`), use the same default dispatch timeout that the Python server uses for these operations (the implementer should verify this value against the Python source rather than guessing) plus the same 5-second slack.

The ExMCP DSL may differ from what's described here — the implementer should consult the current ExMCP v0.9.1 docs and adapt. The important part is the **shape**: five tool handlers delegating to `Agent.dispatch/3` and formatting results consistently.

### Result Formatting

A dedicated result formatter module (`ExCodeRemote.MCP.ResultFormatter` or similar) converts the dispatcher's result tuples and maps into text strings matching the Python server's output shape. This module is shared by all five tool handlers.

**Shell command results (`run_shell_command`):**

- Output text, followed by `[stderr]: <error>` if stderr is non-empty, followed by `[exit_code: N]` if exit code is present.
- Empty results (no stdout, no stderr) become `(no output)`, with exit code appended if present.

**File operation results (`read_file`, `list_directory`):**

- The content or listing string as returned by the agent, or `(no output)` if the response is empty.

**Write confirmation (`write_file`):**

- The confirmation message as returned by the agent (expected to include the path written to).

**Error formatting (all tools):**

The specific error tuples the formatter must handle, at minimum:

- `{:error, :not_connected}` — the machine name does not match any connected agent
- `{:error, :agent_disconnected}` — the agent disconnected while the command was in flight
- `{:error, :timeout}` — the dispatch timed out waiting for the agent's response
- `{:error, :command_timeout}` — the agent reported that the command itself timed out (if this is a distinct error from SPEC-4; the implementer should verify)

The formatter must handle every error tuple that `Agent.dispatch/3` can return. Consult the Agent facade's return types from SPEC-3 and the Dispatcher's error set from SPEC-4 to ensure full coverage. If the formatter encounters an unrecognized error tuple, it should produce a generic "Unexpected error" message rather than crashing or leaking internal terms. The generic message should include the error's atom name converted to a readable string (e.g., `:something_unknown` becomes "Unexpected error: something unknown") so that debugging is possible without exposing raw Elixir terms.

For successful command results, the formatter must handle the following variations in the result map:

- Result has stdout only (stderr empty or absent, no exit code)
- Result has stdout and non-zero exit code
- Result has stdout, stderr, and exit code
- Result has no stdout, no stderr, exit code zero (successful but silent command)
- Result has no stdout, no stderr, no exit code (e.g. file operation confirmations)

### Router Integration

Mount ExMCP's HttpPlug at the appropriate path in the Plug router (depending on what ExMCP expects for the SSE transport). No auth plug is applied to MCP routes — the transport is intentionally public.

The exact mount path depends on ExMCP's transport expectations. The implementer should verify what paths the MCP SSE transport requires and ensure the router forwards to them correctly. Existing routes in the router (WebSocket upgrade for agent connections at `/ws/agent`, health check at `/health`) must not be disrupted by the new MCP mount.

The ordering of route definitions in the Plug router matters — the MCP forward must not shadow the existing WebSocket upgrade path or health check route. The implementer should verify route precedence by testing that all existing routes still respond correctly after the MCP mount is added. If the MCP mount is a catch-all forward, it must be placed after more specific routes.

Once the mount path is determined, it must be documented (in the project README or a configuration note) so that SPEC-8's cutover plan can reference the correct MCP endpoint URL for Claude.ai connector configuration.

### Supervision

The MCP server process must be added as a child of the application supervisor. It should be started after the Agent registry so that `Agent.list/0` and `Agent.dispatch/3` are available when tool calls arrive. Use a standard restart strategy — if the MCP server crashes, it should restart without affecting agent connections or in-flight dispatches.

The MCP server and the Agent registry must not have a hard dependency on each other's liveness — a crash in the MCP server must not cascade to the registry, and vice versa. Verify that the supervision tree's restart strategy enforces this isolation (e.g., the MCP server should not be in a `one_for_all` group with the Agent registry).

### Concurrency

Multiple MCP clients may connect simultaneously, and a single client may issue overlapping tool calls. Since each tool handler delegates to `Agent.dispatch/3` (which is already designed for concurrent use per SPEC-4), the MCP server does not need additional serialization. However, the implementer should verify that ExMCP's server process model supports concurrent tool call handling — if ExMCP serializes incoming calls through a single process, that is acceptable for now but should be noted as a future scaling concern.

If the ExMCP server process is a single GenServer that blocks on each tool call, and our tool calls can take up to 65 seconds (60-second timeout plus 5-second slack), then a second MCP client's tool call would be blocked for the full duration of the first. The implementer should confirm whether ExMCP spawns per-request processes or serializes, and document the finding in a comment on the server module.

## How to Evaluate

### Definition of Done

This spec is complete when a Claude.ai user can perform their normal workflow — running commands, reading and writing files, listing directories, checking agent status — against the new Elixir server and experience no difference from the Python server. "No difference" means: the same tools appear, the same arguments work, the same output comes back, and errors are clear enough to act on.

### Success Criteria

- [ ] `ExCodeRemote.MCP.Server` exports five tools with the schemas above
- [ ] Tool argument schemas specify required versus optional arguments correctly, and argument types match the definitions in this spec
- [ ] Tool descriptions in the MCP tool listing match the Python server's descriptions closely enough that Claude.ai produces equivalent tool calls — verified by comparing the output of a `tools/list` request against the Python server's tool listing
- [ ] `check_agent_status` returns the correct list of connected machines
- [ ] `check_agent_status` returns "No agents are connected." (exact string) when no agents are connected
- [ ] `check_agent_status` returns a single machine name with no commas or trailing punctuation when exactly one agent is connected
- [ ] Each command-dispatching tool successfully routes through `Agent.dispatch/3` and returns a formatted result
- [ ] Error paths (`:not_connected`, `:agent_disconnected`, `:timeout`) return non-empty, readable error text — each error produces a distinct message that tells the user what happened
- [ ] An unrecognized error tuple from the dispatcher produces a generic error message rather than a crash
- [ ] The result formatter produces output matching the Python server's format for shell commands: stdout text, then stderr on a separate labeled line if present, then exit code on a separate labeled line if present
- [ ] The result formatter produces correct output for non-shell-command tools: file content for `read_file`, confirmation with path for `write_file`, directory listing for `list_directory`
- [ ] Missing or invalid required arguments (empty `machine`, missing `command`, wrong type) return a clear validation error, not a crash
- [ ] ExMCP transport is mounted in the router and the MCP endpoint is reachable without authentication
- [ ] Existing router routes (WebSocket agent connections at `/ws/agent`, health check at `/health`) continue to work after the MCP mount is added
- [ ] The MCP server is a supervised child process that starts automatically with the application
- [ ] The MCP server can crash and restart without affecting agent connections or in-flight dispatches on other processes
- [ ] Claude.ai (or any MCP client) can list tools and call them against a connected agent
- [ ] The Python agent does not need any changes to work with this MCP surface
- [ ] The MCP endpoint path is documented so SPEC-8's cutover plan and operators know what URL to give Claude.ai

### Behavioral Equivalence Verification

The following comparisons must be performed during validation to confirm the new server is a drop-in replacement. These are not optional — they are the core of the customer promise:

- The tool names returned by `tools/list` on the Elixir server must exactly match those returned by the Python server
- The argument names and types for each tool must match between servers
- For the same shell command executed against the same agent, the output text returned through the Elixir server must be indistinguishable from the output returned through the Python server
- Error messages for common failure modes (agent not connected, command timeout) must be clear and actionable — they do not need to be identical to the Python server's errors, but they must convey the same information

### Tests

Tests should be included with the implementation changes, reusing the FakeAgent or WSClient helper from SPEC-4/SPEC-3:

- **Per-tool unit tests**: each of the five tools called with a connected fake agent returns the expected output shape. This includes verifying `read_file` returns file content, `write_file` returns a confirmation with the path, and `list_directory` returns a listing — not just `run_shell_command`.
- **Error tests**: calling a tool against an unknown machine returns the "not connected" error text. Calling a tool when the agent disconnects mid-request returns the "agent disconnected" error text. Calling a tool that times out returns the timeout error text. Calling a tool where the dispatcher returns an unexpected error reason (not one of the known atoms) returns a generic error message without crashing.
- **`check_agent_status`**: returns "No agents are connected." with no agents, lists both names with two connected agents, returns updated list after an agent disconnects. Also verify that a single connected agent returns just the name with no commas or trailing punctuation.
- **Result formatter**: non-empty output is trimmed, empty output becomes "(no output)", stderr and exit code are appended correctly. An unrecognized error tuple produces a generic error message. All result map variations listed in the Result Formatting section above are covered as individual test cases. Separate tests for each tool type's formatting path (shell command vs. file read vs. write confirmation vs. directory listing).
- **Input edge cases**: `run_shell_command` with a zero or negative timeout clamps to one second. A tool call with a `machine` value of empty string returns a clear error (either "not connected" or a validation message), not a crash. A tool call with a missing required argument (e.g. `read_file` without `path`) returns a validation error.
- **HTTP integration test**: start Bandit on an ephemeral port, issue an MCP `tools/list` request, assert five tools present with correct argument schemas. Issue a `tools/call` for `check_agent_status`, assert response.
- **End-to-end**: issue a `tools/call` for `run_shell_command` with a connected fake agent, assert the result comes back correctly. Issue a `tools/call` for `read_file` with a connected fake agent, assert the result comes back correctly. These two tools exercise both the shell-command formatting path and the file-content formatting path.
- **Router coexistence**: verify that the WebSocket upgrade path for agent connections at `/ws/agent` still works after the MCP mount is added. Verify that the health check endpoint at `/health` still works after the MCP mount is added.
- **Concurrent tool calls**: issue two overlapping `run_shell_command` calls against two different fake agents and verify both complete independently. This validates that the MCP-to-dispatch path does not serialize unrelated requests.
- **Supervision restart**: stop the MCP server process, verify it restarts automatically, and verify that tool calls work again after restart without affecting existing agent connections.

### Validation

- `mix test` passes
- Manual: point a Claude.ai connector at the MCP endpoint, list tools, run `check_agent_status`, run a shell command against a connected Python agent
- Manual: confirm that the tool names, argument schemas, and descriptions shown by Claude.ai match what the Python server exposes — this validates that existing connector configurations will work without changes
- Manual: with two agents connected, verify that `check_agent_status` lists both names and that commands can be routed to each by specifying the correct `machine` value
- Manual: read a file and list a directory via MCP to verify that non-shell-command tools work end-to-end (not just `run_shell_command`)
- Manual: perform a side-by-side comparison — connect the same agent to both the Python and Elixir servers simultaneously and run the same sequence of operations through each, comparing the results Claude.ai receives

## Notes

- The ExMCP DSL may evolve between v0.9.x releases. Pin the version and re-run tests before bumping.
- `check_agent_status` is deliberately the only tool that does not touch the dispatcher — it's a pure query over `Agent.list/0`.
- The result formatter is deliberately simple — it mirrors what the Python version builds as a single string. Structured tool responses are a potential future improvement but are out of scope.
- This is the first spec where the real Python agent should be tested against the new server end-to-end. Run the manual validation early.
- The default timeout for non-shell-command tools (`read_file`, `write_file`, `list_directory`) is not exposed to the MCP caller. If agents are slow to respond for file operations (large files, slow disks), the fixed default timeout may need revisiting — but for now, a reasonable default matching the Python server's behavior is sufficient. The implementer should verify the Python server's default timeout for these operations rather than picking an arbitrary value.
- The ExMCP API investigation (determining mount paths, server definition patterns, and concurrency model) should be treated as the first concrete implementation step — findings from this investigation may require adjustments to the router integration or supervision approach described above. If the ExMCP API does not support the patterns assumed here (e.g., if it requires a different transport mechanism than HttpPlug, or if it does not support tool registration in the expected way), the implementer should document the divergence and adapt rather than forcing a mismatch.
- The Python server source (at `~/code/code-remote/`) is the single source of truth for tool description strings and output format. If there is any ambiguity in what a description or formatted result should say, defer to the Python source, not this spec.

## Observations

- [decision] Five-tool surface frozen to match Python — lets Claude.ai connector configs move over with a URL change only
- [decision] `machine` as a required argument on every dispatch-type tool — the server supports multiple agents, and the tool call must say which one
- [decision] `check_agent_status` as a tool, not a separate endpoint — MCP clients already discover tools, no reason to make this an out-of-band call
- [decision] MCP transport is unauthenticated — matches the Python server; agent auth and Tailscale protect the execution path
- [decision] Tool handlers call `Agent.dispatch/3`, not `Dispatcher.run/2` directly — the facade is the stable API boundary
- [decision] Result formatter matches Python's string shape — avoids breaking any downstream assumptions in existing Claude.ai conversations
- [decision] MCP server is supervised but does not need to be ordered before agent connections — it only needs the Agent registry to be available, which starts before any connections arrive
- [decision] Result formatter is its own module, not inline in the server — it can be tested independently against hardcoded inputs without ExMCP
- [risk] ExMCP DSL API may churn before v1.0; keep the tool module small and co-locate the macro usage so a future migration is localized
- [risk] If ExMCP serializes tool calls through a single GenServer, concurrent MCP clients will queue behind each other; acceptable for initial deployment but may need attention if multiple Claude.ai sessions use the server simultaneously
- [risk] Tool descriptions must closely match the Python server's descriptions or Claude.ai may generate different argument patterns — verify descriptions against the Python source during implementation
- [risk] Route ordering in the Plug router could cause the MCP forward to shadow existing routes if placed before more specific matches — verify route precedence during router integration
- [risk] The MCP endpoint URL chosen during router integration becomes a downstream dependency for SPEC-8's cutover plan — document it immediately once determined
- [pattern] All handlers are one-liners delegating to `Agent.dispatch/3` plus result formatting — the MCP module is a thin translation layer, not a business logic layer
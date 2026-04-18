#!/usr/bin/env python3
"""
Code Remote Agent

Headless daemon that connects to the relay service and executes commands.
Runs on your machine, auto-executes approved commands from AI assistants.
"""

import asyncio
import json
import os
import signal
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import websockets
from websockets.exceptions import ConnectionClosed

# --- Configuration ---

# IMPORTANT: Set RELAY_URL, AUTH_TOKEN, and MACHINE_NAME in .env file
# Format: wss://YOUR-APP-NAME.fly.dev/ws/agent
RELAY_URL = os.getenv("RELAY_URL", "")
AUTH_TOKEN = os.getenv("AUTH_TOKEN", "")
MACHINE_NAME = os.getenv("MACHINE_NAME", "")
RECONNECT_DELAY = 5  # seconds
MAX_OUTPUT_SIZE = 1_000_000  # 1MB max output
DEFAULT_SHELL = os.getenv("SHELL", "/bin/sh")

# Safety: directories the agent is allowed to access
ALLOWED_PATHS = [
    Path.home(),
    Path("/tmp"),
    Path("/var/tmp"),
]

# --- Logging ---

def log(message: str):
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {message}", flush=True)


def log_error(message: str):
    log(f"ERROR: {message}")


# --- Path Safety ---

def is_path_allowed(path_str: str) -> bool:
    """Check if a path is within allowed directories"""
    try:
        path = Path(path_str).expanduser().resolve()
        return any(
            path == allowed or allowed in path.parents
            for allowed in ALLOWED_PATHS
        )
    except Exception:
        return False


# --- Command Execution ---

async def _reap_eventually(process: asyncio.subprocess.Process):
    """Background task that waits indefinitely for a stuck subprocess to die.

    Used when a process is in uninterruptible kernel wait (D state) and
    process.wait() would block the event loop. This frees the main command
    handler while still eventually reaping the zombie whenever the process
    finally exits.

    Logs a heartbeat periodically so we have visibility into how long a
    subprocess has been unkillable.
    """
    pid = process.pid
    started = datetime.now(timezone.utc)
    heartbeat_intervals = [60, 300, 900, 1800, 3600]  # 1m, 5m, 15m, 30m, 1h
    next_heartbeat_idx = 0

    while True:
        delay = (
            heartbeat_intervals[next_heartbeat_idx]
            if next_heartbeat_idx < len(heartbeat_intervals)
            else 3600
        )
        try:
            await asyncio.wait_for(process.wait(), timeout=delay)
            elapsed = (datetime.now(timezone.utc) - started).total_seconds()
            log(f"Background reaper: pid {pid} finally exited after {elapsed:.0f}s")
            return
        except asyncio.TimeoutError:
            elapsed = (datetime.now(timezone.utc) - started).total_seconds()
            log_error(
                f"Background reaper: pid {pid} still unkillable after {elapsed:.0f}s"
            )
            if next_heartbeat_idx < len(heartbeat_intervals) - 1:
                next_heartbeat_idx += 1
        except Exception as e:
            log_error(f"Background reaper for pid {pid} failed: {e}")
            return


def _kill_process_group(process: asyncio.subprocess.Process):
    """Send SIGKILL to the entire process group of a subprocess.

    Without this, only the shell is killed and children like `find`, `xargs`,
    `grep` keep running. Requires the process to have been spawned with
    start_new_session=True so it has its own process group.
    """
    try:
        pgid = os.getpgid(process.pid)
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except Exception as e:
        log_error(f"Failed to kill process group for pid {process.pid}: {e}")
        try:
            process.kill()
        except Exception:
            pass


async def execute_shell(command: str, working_dir: Optional[str], timeout: int) -> dict:
    """Execute a shell command"""
    log(f"Executing: {command}")

    cwd = None
    if working_dir:
        cwd = Path(working_dir).expanduser().resolve()
        if not is_path_allowed(str(cwd)):
            return {
                "status": "failed",
                "error": f"Working directory not allowed: {working_dir}",
                "exit_code": 1
            }

    try:
        # stdin=DEVNULL prevents commands from hanging waiting for interactive input
        # start_new_session=True puts the shell in its own process group so we can
        # kill the whole pipeline (find | xargs | grep) on timeout, not just the shell
        process = await asyncio.create_subprocess_shell(
            command,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=cwd,
            shell=True,
            executable=DEFAULT_SHELL,
            start_new_session=True,
        )

        try:
            stdout, stderr = await asyncio.wait_for(
                process.communicate(),
                timeout=timeout
            )
        except asyncio.TimeoutError:
            _kill_process_group(process)
            # Give the process group a brief window to die. If it's stuck in
            # uninterruptible kernel wait (e.g., hung filesystem, iCloud, TCC),
            # SIGKILL won't take effect until the kernel call returns. Spawn a
            # background reaper so we don't block the event loop forever.
            try:
                await asyncio.wait_for(process.wait(), timeout=2.0)
            except asyncio.TimeoutError:
                log_error(
                    f"Subprocess pid {process.pid} did not exit after SIGKILL; "
                    "likely stuck in kernel wait. Abandoning to background reaper."
                )
                asyncio.create_task(_reap_eventually(process))
            return {
                "status": "timeout",
                "error": f"Command timed out after {timeout} seconds",
                "exit_code": -1
            }
        
        output = stdout.decode("utf-8", errors="replace")
        error = stderr.decode("utf-8", errors="replace")
        
        # Truncate if too large
        if len(output) > MAX_OUTPUT_SIZE:
            output = output[:MAX_OUTPUT_SIZE] + "\n... (output truncated)"
        if len(error) > MAX_OUTPUT_SIZE:
            error = error[:MAX_OUTPUT_SIZE] + "\n... (error truncated)"
        
        return {
            "status": "completed" if process.returncode == 0 else "failed",
            "output": output,
            "error": error if error else None,
            "exit_code": process.returncode
        }
    
    except Exception as e:
        log_error(f"Shell execution error: {e}")
        return {
            "status": "failed",
            "error": str(e),
            "exit_code": 1
        }


async def read_file(path_str: str) -> dict:
    """Read a file's contents"""
    log(f"Reading file: {path_str}")
    
    try:
        path = Path(path_str).expanduser().resolve()
        
        if not is_path_allowed(str(path)):
            return {
                "status": "failed",
                "error": f"Path not allowed: {path_str}",
                "exit_code": 1
            }
        
        if not path.exists():
            return {
                "status": "failed",
                "error": f"File not found: {path_str}",
                "exit_code": 1
            }
        
        if not path.is_file():
            return {
                "status": "failed",
                "error": f"Not a file: {path_str}",
                "exit_code": 1
            }
        
        content = path.read_text(errors="replace")
        
        if len(content) > MAX_OUTPUT_SIZE:
            content = content[:MAX_OUTPUT_SIZE] + "\n... (content truncated)"
        
        return {
            "status": "completed",
            "output": content,
            "exit_code": 0
        }
    
    except Exception as e:
        log_error(f"Read file error: {e}")
        return {
            "status": "failed",
            "error": str(e),
            "exit_code": 1
        }


async def write_file(path_str: str, content: str) -> dict:
    """Write content to a file"""
    log(f"Writing file: {path_str}")
    
    try:
        path = Path(path_str).expanduser().resolve()
        
        if not is_path_allowed(str(path)):
            return {
                "status": "failed",
                "error": f"Path not allowed: {path_str}",
                "exit_code": 1
            }
        
        # Create parent directories if needed
        path.parent.mkdir(parents=True, exist_ok=True)
        
        path.write_text(content)
        
        return {
            "status": "completed",
            "output": f"Written {len(content)} bytes to {path}",
            "exit_code": 0
        }
    
    except Exception as e:
        log_error(f"Write file error: {e}")
        return {
            "status": "failed",
            "error": str(e),
            "exit_code": 1
        }


async def list_dir(path_str: str) -> dict:
    """List directory contents"""
    log(f"Listing directory: {path_str}")
    
    try:
        path = Path(path_str).expanduser().resolve()
        
        if not is_path_allowed(str(path)):
            return {
                "status": "failed",
                "error": f"Path not allowed: {path_str}",
                "exit_code": 1
            }
        
        if not path.exists():
            return {
                "status": "failed",
                "error": f"Directory not found: {path_str}",
                "exit_code": 1
            }
        
        if not path.is_dir():
            return {
                "status": "failed",
                "error": f"Not a directory: {path_str}",
                "exit_code": 1
            }
        
        entries = []
        for entry in sorted(path.iterdir()):
            entry_type = "dir" if entry.is_dir() else "file"
            try:
                size = entry.stat().st_size if entry.is_file() else 0
            except:
                size = 0
            entries.append(f"{entry_type}\t{size}\t{entry.name}")
        
        return {
            "status": "completed",
            "output": "\n".join(entries),
            "exit_code": 0
        }
    
    except Exception as e:
        log_error(f"List dir error: {e}")
        return {
            "status": "failed",
            "error": str(e),
            "exit_code": 1
        }


async def handle_command(data: dict) -> dict:
    """Route command to appropriate handler"""
    command_type = data.get("command_type")
    command_id = data.get("id")
    
    log(f"Received command {command_id}: {command_type}")
    
    if command_type == "shell":
        result = await execute_shell(
            data.get("command", ""),
            data.get("working_dir"),
            data.get("timeout", 60)
        )
    elif command_type == "read_file":
        result = await read_file(data.get("path", ""))
    elif command_type == "write_file":
        result = await write_file(data.get("path", ""), data.get("content", ""))
    elif command_type == "list_dir":
        result = await list_dir(data.get("path", ""))
    else:
        result = {
            "status": "failed",
            "error": f"Unknown command type: {command_type}",
            "exit_code": 1
        }
    
    return {
        "type": "result",
        "id": command_id,
        **result
    }


# --- WebSocket Connection ---

async def connect_and_run():
    """Connect to relay and process commands.

    Command execution is offloaded to background tasks so the message loop
    remains responsive to WebSocket pings. Without this, a long-running
    command (e.g. 60s shell) blocks the ``async for message in ws`` iterator
    which prevents the websockets library from processing ping/pong frames,
    causing the connection to be declared dead.
    """
    url = f"{RELAY_URL}?token={AUTH_TOKEN}&machine={MACHINE_NAME}"

    log(f"Connecting to relay...")

    # Disable the library's built-in ping so we handle keep-alive ourselves.
    # The library ping requires the message loop to be free to process pong
    # frames, but our message loop may be waiting on receive while a command
    # task is running. Instead, we use application-level pings on a separate
    # task that can always send regardless of what the message loop is doing.
    async with websockets.connect(
        url,
        ping_interval=None,
        ping_timeout=None,
        close_timeout=5
    ) as ws:
        log("Connected to relay!")
        connected_at = datetime.now(timezone.utc)

        # Track in-flight command tasks for clean shutdown
        command_tasks: set[asyncio.Task] = set()

        async def _run_command(data: dict):
            """Execute a command and send the result back over the WebSocket."""
            command_id = data.get("id", "?")
            started = datetime.now(timezone.utc)
            try:
                result = await handle_command(data)
                duration = (datetime.now(timezone.utc) - started).total_seconds()
                log(
                    f"Command {command_id} {result.get('status', 'unknown')} "
                    f"in {duration:.1f}s"
                )
                await ws.send(json.dumps(result))
            except Exception as e:
                log_error(f"Command {command_id} failed to send result: {e}")

        # Application-level ping to keep connection alive.
        # Runs independently of the message loop so it works even while
        # commands are executing.
        async def ping_loop():
            while True:
                await asyncio.sleep(25)
                try:
                    await ws.send(json.dumps({"type": "ping"}))
                except Exception:
                    break

        ping_task = asyncio.create_task(ping_loop())

        try:
            async for message in ws:
                data = json.loads(message)
                msg_type = data.get("type")

                if msg_type == "execute":
                    # Spawn command in background so the message loop stays
                    # free to process pings and other messages.
                    task = asyncio.create_task(_run_command(data))
                    command_tasks.add(task)
                    task.add_done_callback(command_tasks.discard)
                elif msg_type == "ping":
                    # Server-originated ping (keep-alive). Respond with pong.
                    try:
                        await ws.send(json.dumps({"type": "pong"}))
                    except Exception:
                        pass
                elif msg_type == "pong":
                    pass  # Response to our own ping, ignore
                else:
                    log(f"Unknown message type: {msg_type}")

        finally:
            ping_task.cancel()
            # Wait briefly for in-flight commands to finish sending results
            if command_tasks:
                log(f"Waiting for {len(command_tasks)} in-flight command(s)...")
                done, pending = await asyncio.wait(command_tasks, timeout=5.0)
                for t in pending:
                    t.cancel()
            duration = (datetime.now(timezone.utc) - connected_at).total_seconds()
            log(f"Session ended after {duration:.1f}s")


async def main():
    """Main loop with reconnection"""
    if not RELAY_URL:
        log_error("RELAY_URL environment variable not set!")
        log_error("Set it in .env file: RELAY_URL=wss://YOUR-APP-NAME.fly.dev/ws/agent")
        sys.exit(1)

    if not AUTH_TOKEN:
        log_error("AUTH_TOKEN environment variable not set!")
        sys.exit(1)

    if not MACHINE_NAME:
        log_error("MACHINE_NAME environment variable not set!")
        sys.exit(1)

    log("Code Remote Agent starting...")
    log(f"Machine name: {MACHINE_NAME}")
    log(f"Relay URL: {RELAY_URL.split('?')[0]}")
    log(f"Home directory: {Path.home()}")
    
    while True:
        try:
            await connect_and_run()
        except ConnectionClosed as e:
            code = getattr(e, "code", None)
            reason = getattr(e, "reason", "") or ""
            log(f"Connection closed: code={code} reason={reason!r} detail={e}")
        except Exception as e:
            log_error(f"Connection error: {type(e).__name__}: {e}")

        log(f"Reconnecting in {RECONNECT_DELAY} seconds...")
        await asyncio.sleep(RECONNECT_DELAY)


if __name__ == "__main__":
    # Handle Ctrl+C gracefully
    def signal_handler(sig, frame):
        log("Shutting down...")
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    asyncio.run(main())

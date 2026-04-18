# Code Remote Agent

Python daemon that connects to the [ex_code_remote](../) server via WebSocket and executes commands on your machine. AI clients (Claude.ai, Claude Code) dispatch commands through the server; the agent runs them locally and sends results back.

## Requirements

- Python 3.11+
- [uv](https://docs.astral.sh/uv/) (for dependency management)

## Quick start

```sh
./setup.sh
./run.sh
```

The setup script creates a virtual environment, installs the one dependency (`websockets`), and prompts for your server URL, auth token, and machine name.

## Configuration

Copy `.env.example` to `.env` and fill in your values:

| Variable | Description |
|----------|-------------|
| `RELAY_URL` | WebSocket URL to the server. Use `ws://` over Tailscale, `wss://` over the public internet. |
| `AUTH_TOKEN` | Must match the `AUTH_TOKEN` configured on the server. |
| `MACHINE_NAME` | Unique name for this machine -- this is what appears in `check_agent_status`. |

## Running as a service

### macOS (launchd)

Edit `com.code.remote-agent.plist` -- replace `YOUR_USERNAME` and the path -- then:

```sh
cp com.code.remote-agent.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.code.remote-agent.plist
```

The agent starts on login and restarts automatically if it crashes. Logs go to `agent/logs/`.

To stop:

```sh
launchctl unload ~/Library/LaunchAgents/com.code.remote-agent.plist
```

### Docker

```sh
docker build -t code-remote-agent .
docker run -d \
  -e RELAY_URL=ws://100.x.x.x:8080/ws/agent \
  -e AUTH_TOKEN=your-token \
  -e MACHINE_NAME=my-docker-agent \
  code-remote-agent
```

The Docker image includes common dev tools (git, ripgrep, jq, build-essential) and runs as a non-root user.

### Linux (systemd)

Create `/etc/systemd/system/code-remote-agent.service`:

```ini
[Unit]
Description=Code Remote Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=your-user
WorkingDirectory=/path/to/ex-code-remote/agent
ExecStart=/path/to/ex-code-remote/agent/run.sh
Restart=always
RestartSec=5
EnvironmentFile=/path/to/ex-code-remote/agent/.env

[Install]
WantedBy=multi-user.target
```

Then:

```sh
sudo systemctl enable --now code-remote-agent
```

## What it does

The agent handles four command types from the server:

| Command | Description |
|---------|-------------|
| `shell` | Run a shell command with timeout and output capture |
| `read_file` | Read and return file contents |
| `write_file` | Write content to a file, creating parent directories |
| `list_dir` | List directory entries with type and size |

All file operations are restricted to the user's home directory, `/tmp`, and `/var/tmp`. The agent reconnects automatically if the connection drops.

## Logs

When run via `run.sh`, logs go to `agent/logs/agent.log` with 10MB rotation and 10 backups. When run via launchd, stdout/stderr also go to `agent/logs/`.

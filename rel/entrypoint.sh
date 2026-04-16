#!/bin/sh
set -e

# --- Tailscale (optional) ---
if [ -n "$TAILSCALE_AUTHKEY" ]; then
  echo "Starting Tailscale daemon..."

  # Persist the tailnet state on the mounted volume so the same nodekey
  # (and therefore the same Tailscale IP) is reused across machine restarts
  # and deploys. Otherwise every boot creates a new tailnet node, MagicDNS
  # lags behind, and clients that hardcoded the previous IP can't reconnect.
  TS_STATEDIR=/data/tailscale
  mkdir -p "$TS_STATEDIR"

  tailscaled --tun=userspace-networking --statedir="$TS_STATEDIR" &

  # Determine a stable hostname for the tailnet node
  TS_HOSTNAME="${FLY_APP_NAME:-ex-code-remote}"

  echo "Connecting to tailnet as ${TS_HOSTNAME}..."
  if tailscale up --authkey="$TAILSCALE_AUTHKEY" --hostname="$TS_HOSTNAME" --timeout=30s; then
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
    echo "Tailscale connected as ${TS_HOSTNAME} with IP ${TS_IP}"
  else
    echo "Tailscale failed to start. Exiting."
    exit 1
  fi
else
  echo "TAILSCALE_AUTHKEY not set, skipping Tailscale."
fi

# --- Migrations ---
echo "Running migrations..."
/app/bin/ex_code_remote eval "ExCodeRemote.Release.migrate()"

# --- Start server ---
echo "Migrations complete. Starting server..."
exec /app/bin/ex_code_remote start

#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/agent.log"
MAX_SIZE=$((10 * 1024 * 1024))  # 10MB
MAX_BACKUPS=10

mkdir -p "$LOG_DIR"

# Rotate if log exceeds max size
if [[ -f "$LOG_FILE" ]] && [[ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt $MAX_SIZE ]]; then
    # Shift existing backups
    for i in $(seq $((MAX_BACKUPS - 1)) -1 1); do
        [[ -f "$LOG_FILE.$i" ]] && mv "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))"
    done
    mv "$LOG_FILE" "$LOG_FILE.1"
fi

source "$SCRIPT_DIR/.env"
source "$SCRIPT_DIR/.venv/bin/activate"
export RELAY_URL AUTH_TOKEN MACHINE_NAME

python3 "$SCRIPT_DIR/agent.py" 2>&1 | tee -a "$LOG_FILE"

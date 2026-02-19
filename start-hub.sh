#!/bin/bash
# Sixel Teams — Hub Launcher
#
# Starts watcher and watchdog if not already running.
# Safe to call multiple times (idempotent).
# Add to session startup hook or container entrypoint.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

if [ -f "$LOCK_FILE" ]; then
    if pgrep -f "bash.*watcher.sh" >/dev/null && pgrep -f "bash.*watchdog.sh" >/dev/null; then
        exit 0
    fi
fi

mkdir -p "$HEARTBEAT_DIR" "$MANIFEST_DIR"
mkdir -p "$OUTBOUND_DIR" "$THREAD_DIR"

cd "$HUB_DIR"
nohup bash watcher.sh  >/tmp/sixel-teams-watcher.log  2>&1 &
nohup bash watchdog.sh >/tmp/sixel-teams-watchdog.log 2>&1 &

touch "$LOCK_FILE"
echo "[sixel-teams] Watcher and watchdog started."

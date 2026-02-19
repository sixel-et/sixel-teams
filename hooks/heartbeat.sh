#!/bin/bash
# Hook: UserPromptSubmit — heartbeat
#
# Touches a heartbeat file on every user/agent interaction.
# The watchdog monitors these to detect idle sessions.
#
# Wire this into your Claude Code settings.json:
#   { "event": "UserPromptSubmit", "command": "/path/to/hooks/heartbeat.sh" }

set -euo pipefail

HEARTBEAT_DIR="/tmp/hubless-heartbeats"

find_claude_pid() {
    local pid=$$
    while [ "$pid" -gt 1 ]; do
        local parent
        parent=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
        [ -z "$parent" ] && break
        local comm
        comm=$(ps -p "$parent" -o comm= 2>/dev/null | tr -d ' ')
        if [ "$comm" = "claude" ]; then
            echo "$parent"
            return
        fi
        pid="$parent"
    done
    echo ""
}

CLAUDE_PID=$(find_claude_pid)
[ -z "$CLAUDE_PID" ] && exit 0

mkdir -p "$HEARTBEAT_DIR"
touch "$HEARTBEAT_DIR/user-${CLAUDE_PID}"

exit 0

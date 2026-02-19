#!/bin/bash
# Hook: SessionStart — bootstrap
#
# Starts the hub (watcher + watchdog), writes a manifest,
# and checks for unread peer messages.
#
# Wire this into your Claude Code settings.json:
#   { "event": "SessionStart", "command": "/path/to/hooks/startup.sh" }

set -euo pipefail

# UPDATE THIS to point to your hubless-teams directory
HUB_DIR="${HUB_DIR:-$HOME/hubless-teams}"

MANIFEST_DIR="/tmp/hubless-manifests"
HEARTBEAT_DIR="/tmp/hubless-heartbeats"

mkdir -p "$MANIFEST_DIR" "$HEARTBEAT_DIR"

# Start watcher + watchdog if not already running
"$HUB_DIR/start-hub.sh" 2>/dev/null || true

# Find the Claude PID
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

# Write manifest
MANIFEST="$MANIFEST_DIR/manifest-$CLAUDE_PID"
if [ ! -f "$MANIFEST" ]; then
    cat > "$MANIFEST" <<EOF
pid: ${CLAUDE_PID}
project: $(pwd)
updated: $(date -Iseconds)
EOF
fi

echo "=== HUB BOOTSTRAP ==="
echo "PID: $CLAUDE_PID"
echo "Manifest: $MANIFEST"
echo "To respond to emails: AGENT_PID=$CLAUDE_PID bash $HUB_DIR/respond.sh contribute <dir> \"your response\""

# Check for unread peer messages
TMUX_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
if [ -n "$TMUX_SESSION" ]; then
    # Derive peer name from session name — customize this for your naming convention
    PEER_NAME=$(echo "$TMUX_SESSION" | sed 's/^.*-//')
    "$HUB_DIR/check-peer-messages.sh" "$PEER_NAME" 2>/dev/null || true
fi

echo "=== END BOOTSTRAP ==="

exit 0

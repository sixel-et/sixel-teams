#!/bin/bash
# Hook: SessionStart (compact matcher) — post-compaction recovery
#
# Re-injects PID, manifest, pending work items, and peer messages
# after context compaction.
#
# Wire this into your Claude Code settings.json:
#   { "event": "SessionStart", "matcher": "compact", "command": "/path/to/hooks/post-compact.sh" }

set -euo pipefail

# UPDATE THIS to point to your sixel-teams directory
HUB_DIR="${HUB_DIR:-$HOME/sixel-teams}"

MANIFEST_DIR="/tmp/sixel-teams-manifests"
OUTBOUND_DIR="$HUB_DIR/state/outbound"

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
    # Fallback: find any living manifest
    for f in "$MANIFEST_DIR"/manifest-*; do
        [ -f "$f" ] || continue
        local mpid
        mpid=$(basename "$f" | sed 's/manifest-//')
        if kill -0 "$mpid" 2>/dev/null; then
            echo "$mpid"
            return
        fi
    done
    echo ""
}

CLAUDE_PID=$(find_claude_pid)

echo "=== POST-COMPACTION CONTEXT ==="
echo ""
echo "Your Claude process PID is: ${CLAUDE_PID:-UNKNOWN}"
echo ""

if [ -n "$CLAUDE_PID" ]; then
    MANIFEST="$MANIFEST_DIR/manifest-$CLAUDE_PID"
    if [ -f "$MANIFEST" ]; then
        cat "$MANIFEST"
    else
        echo "No manifest found. Write one to: $MANIFEST"
    fi

    echo ""
    echo "Hub scripts: $HUB_DIR/"
    echo "To respond to emails: SIXEL_PID=$CLAUDE_PID bash $HUB_DIR/respond.sh contribute <dir> \"your response\""
    echo ""

    # List pending work items
    pending_count=0
    for d in "$OUTBOUND_DIR"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/status.json" ] || continue
        sent_at=$(jq -r '.sent_at // "null"' "$d/status.json" 2>/dev/null)
        [ "$sent_at" != "null" ] && continue
        [ -f "$d/email.json" ] || continue
        subject=$(jq -r '.subject // "(no subject)"' "$d/email.json" 2>/dev/null)
        pending_count=$((pending_count + 1))
        echo "PENDING: $subject (dir: $d)"
    done
    if [ "$pending_count" -eq 0 ]; then
        echo "No pending emails."
    fi

    # Check for unread peer messages
    TMUX_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
    if [ -n "$TMUX_SESSION" ]; then
        PEER_NAME=$(echo "$TMUX_SESSION" | sed 's/^.*-//')
        "$HUB_DIR/check-peer-messages.sh" "$PEER_NAME" 2>/dev/null || true
    fi
fi

echo ""
echo "=== END POST-COMPACTION CONTEXT ==="

exit 0

#!/bin/bash
# Hubless Teams — Peer Message Scanner
#
# Usage: check-peer-messages.sh <peer-name>
# Outputs any unread messages addressed to this peer.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PEER_NAME="${1:-}"
[ -z "$PEER_NAME" ] && exit 0

SEEN_FILE="${STATE_DIR}/peer-seen-${PEER_NAME}"

# Pull latest (quietly)
cd "$HUB_DIR" && git pull -q 2>/dev/null || true

touch "$SEEN_FILE"

[ -d "$MSG_DIR" ] || exit 0

unread_count=0
for msg in "$MSG_DIR"/*-to-"${PEER_NAME}".json; do
    [ -f "$msg" ] || continue
    basename=$(basename "$msg")
    if ! grep -qF "$basename" "$SEEN_FILE" 2>/dev/null; then
        subject=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('subject','(no subject)'))" "$msg" 2>/dev/null || echo "(unreadable)")
        from=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('from','unknown'))" "$msg" 2>/dev/null || echo "unknown")
        echo "PEER MESSAGE from $from: $subject (file: $msg)"
        echo "$basename" >> "$SEEN_FILE"
        unread_count=$((unread_count + 1))
    fi
done

if [ "$unread_count" -gt 0 ]; then
    echo "$unread_count unread peer message(s)."
fi

#!/bin/bash
# Sixel Teams — Peer Message Send
#
# Usage: peer-send.sh <from> <to> <subject> <body> [in_reply_to]
#
# Handles: message ID, JSON write, log append, git commit+push, tmux doorbell.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

FROM="$1"
TO="$2"
SUBJECT="$3"
BODY="$4"
IN_REPLY_TO="${5:-null}"

mkdir -p "$MSG_DIR"
touch "$LOG_FILE"

# --- Next message ID ---
LAST_ID=$(ls "$MSG_DIR"/*.json 2>/dev/null | sed 's/.*\///' | sed 's/-.*//' | sort -n | tail -1)
NEXT_ID=$(printf "%03d" $(( 10#${LAST_ID:-000} + 1 )))

FILENAME="${NEXT_ID}-${FROM}-to-${TO}.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
LOG_TIME=$(date -u +"%Y-%m-%d %H:%M UTC")

# --- Build JSON via python for safe quoting ---
python3 -c "
import json, sys
msg = {
    'id': sys.argv[1],
    'from': sys.argv[2],
    'to': sys.argv[3],
    'timestamp': sys.argv[4],
    'subject': sys.argv[5],
    'body': sys.argv[6],
    'in_reply_to': None if sys.argv[7] == 'null' else sys.argv[7]
}
print(json.dumps(msg, indent=2))
" "$NEXT_ID" "$FROM" "$TO" "$TIMESTAMP" "$SUBJECT" "$BODY" "$IN_REPLY_TO" > "$MSG_DIR/$FILENAME"

# --- Append to log ---
cat >> "$LOG_FILE" << LOGEOF

---
### $NEXT_ID | $LOG_TIME | $FROM → $TO
**Subject:** $SUBJECT

$BODY

---
LOGEOF

# --- Git commit + push ---
cd "$HUB_DIR"
git add chat/
git commit -q -m "peer: $FROM → $TO — $SUBJECT"
git push -q

# --- Ring the doorbell ---
if [ -f "$PEERS_FILE" ]; then
    SESSION=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],{}).get('tmux_session',''))" "$PEERS_FILE" "$TO" 2>/dev/null)
    if [ -n "$SESSION" ]; then
        tmux send-keys -t "$SESSION" -l "[peer] Message from $FROM: $SUBJECT" 2>/dev/null || true
        tmux send-keys -t "$SESSION" Enter 2>/dev/null || true
    fi
fi

echo "$NEXT_ID"

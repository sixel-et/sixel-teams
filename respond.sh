#!/bin/bash
# Hubless Teams — Response Helper
#
# Used by agent sessions to respond to work items.
#
# Usage:
#   ./respond.sh contribute <email-dir> <content> [position]
#   ./respond.sh pass <email-dir>
#   ./respond.sh primary <email-dir> <content> <subject>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

CLAUDE_PID="${AGENT_PID:-$PPID}"

action="${1:?Usage: respond.sh (contribute|pass|primary) <email-dir> [content] [position|subject]}"
email_dir="${2:?Missing email directory}"

project="unknown"
manifest="$MANIFEST_DIR/manifest-$CLAUDE_PID"
[ -f "$manifest" ] && project=$(grep '^project:' "$manifest" | sed 's/^project: *//')

responses_dir="$email_dir/responses"
mkdir -p "$responses_dir"

saw_prior=()
for f in "$responses_dir"/*.json; do
    [ -f "$f" ] || continue
    prior_pid=$(basename "$f" .json)
    saw_prior+=("$prior_pid")
done
saw_prior_json=$(printf '%s\n' "${saw_prior[@]}" 2>/dev/null | jq -R . | jq -s '.' 2>/dev/null || echo '[]')

case "$action" in
    contribute)
        content="${3:?Missing content}"
        position="${4:-99}"
        jq -n \
            --argjson pid "$CLAUDE_PID" \
            --arg project "$project" \
            --arg type "contribution" \
            --argjson position "$position" \
            --argjson saw_prior "$saw_prior_json" \
            --arg content "$content" \
            --arg timestamp "$(date -Iseconds)" \
            '{pid: $pid, project: $project, type: $type, position: $position,
              saw_prior: $saw_prior, content: $content, timestamp: $timestamp}' \
            > "$responses_dir/$CLAUDE_PID.json"
        echo "Contributed to $(basename "$email_dir") at position $position"
        ;;
    pass)
        jq -n \
            --argjson pid "$CLAUDE_PID" \
            --arg project "$project" \
            --arg type "pass" \
            --arg timestamp "$(date -Iseconds)" \
            '{pid: $pid, project: $project, type: $type, timestamp: $timestamp}' \
            > "$responses_dir/$CLAUDE_PID.json"
        echo "Passed on $(basename "$email_dir")"
        ;;
    primary)
        content="${3:?Missing content}"
        subject="${4:?Missing subject for primary outbound}"
        local_id="out_$(date +%s)_${CLAUDE_PID}"
        outbound_dir="$OUTBOUND_DIR/$local_id"
        mkdir -p "$outbound_dir/responses" "$outbound_dir/attachments"

        jq -n \
            --argjson pid "$CLAUDE_PID" \
            --arg project "$project" \
            --arg type "primary" \
            --arg content "$content" \
            --arg timestamp "$(date -Iseconds)" \
            '{pid: $pid, project: $project, type: $type, position: 1,
              saw_prior: [], content: $content, timestamp: $timestamp}' \
            > "$outbound_dir/responses/$CLAUDE_PID.json"

        local slug
        slug=$(echo "$subject" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | head -c 30)
        local thread_id="thread_$(date +%Y%m%d)_${CLAUDE_PID}_${slug}"

        jq -n \
            --arg thread_id "$thread_id" \
            --argjson originating_pid "$CLAUDE_PID" \
            --arg originating_project "$project" \
            --arg outbound_email_id "$local_id" \
            --arg subject "$subject" \
            --arg created "$(date -Iseconds)" \
            '{thread_id: $thread_id, originating_pid: $originating_pid,
              originating_project: $originating_project,
              outbound_email_id: $outbound_email_id,
              subject: $subject, created: $created}' \
            > "$outbound_dir/thread.json"

        echo "Outbound email queued: $local_id (thread: $thread_id)"
        echo "Watcher will detect and send within ${POLL_INTERVAL}s."
        ;;
    *)
        echo "Unknown action: $action" >&2
        echo "Usage: respond.sh (contribute|pass|primary) <email-dir> [content] [position|subject]" >&2
        exit 1
        ;;
esac

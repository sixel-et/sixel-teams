#!/bin/bash
# Hubless Teams — Watcher
#
# Polls an email inbox, stores new messages in per-email directories,
# scans for session responses, assembles and sends replies.
# Pure bash — no inference, no LLM calls.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

mkdir -p "$OUTBOUND_DIR" "$THREAD_DIR"
touch "$SEEN_FILE"

log() {
    echo "[$(date -Iseconds)] $*" >&2
}

# --- Inbox Polling ---

poll_inbox() {
    local response
    response=$(curl -s -H "Authorization: Bearer $INBOX_API_KEY" \
        "$INBOX_API_URL/inbox" 2>/dev/null) || return 1

    local count
    count=$(echo "$response" | jq '.messages | length' 2>/dev/null) || return 1

    if [ "$count" -eq 0 ]; then
        return 0
    fi

    echo "$response" | jq -c '.messages[]' | while read -r msg; do
        local msg_id subject body received_at
        msg_id=$(echo "$msg" | jq -r '.id')
        subject=$(echo "$msg" | jq -r '.subject // ""')
        body=$(echo "$msg" | jq -r '.body')
        received_at=$(echo "$msg" | jq -r '.received_at')

        if grep -qF "$msg_id" "$SEEN_FILE" 2>/dev/null; then
            continue
        fi

        log "New inbound email: $msg_id (subject: $subject)"
        handle_inbound "$msg_id" "$subject" "$body" "$received_at"

        echo "$msg_id" >> "$SEEN_FILE"
    done
}

# --- Inbound Email Handling ---

handle_inbound() {
    local email_id="$1"
    local subject="$2"
    local body="$3"
    local received_at="$4"

    local email_dir="$OUTBOUND_DIR/$email_id"
    mkdir -p "$email_dir/responses" "$email_dir/attachments"

    jq -n \
        --arg id "$email_id" \
        --arg subject "$subject" \
        --arg body "$body" \
        --arg received_at "$received_at" \
        '{id: $id, subject: $subject, body: $body, received_at: $received_at}' \
        > "$email_dir/email.json"

    local thread_id=""
    thread_id=$(match_thread "$subject")
    if [ -n "$thread_id" ]; then
        log "Matched thread: $thread_id"
        cp "$THREAD_DIR/$thread_id.json" "$email_dir/thread.json" 2>/dev/null || true
    fi

    jq -n \
        --arg email_id "$email_id" \
        --arg thread_id "$thread_id" \
        --arg received_at "$received_at" \
        '{
            email_id: $email_id,
            thread_id: $thread_id,
            direction: "inbound",
            received_at: $received_at,
            first_response_at: null,
            assembled_at: null,
            sent_at: null
        }' > "$email_dir/status.json"

    log "Stored inbound email $email_id, waiting for responses"
}

# --- Thread Matching ---

match_thread() {
    local subject="$1"
    local clean_subject
    clean_subject=$(echo "$subject" | sed -E 's/^(Re|Fwd|FW|RE|Fw): *//gi')

    for f in "$THREAD_DIR"/*.json; do
        [ -f "$f" ] || continue
        local thread_subject
        thread_subject=$(jq -r '.subject // ""' "$f" 2>/dev/null)
        local clean_thread
        clean_thread=$(echo "$thread_subject" | sed -E 's/^(Re|Fwd|FW|RE|Fw): *//gi')
        clean_thread=$(echo "$clean_thread" | sed -E 's/^\[.*\] *//')

        if [ "$clean_subject" = "$clean_thread" ]; then
            basename "$f" .json
            return
        fi
    done
    echo ""
}

# --- Response Scanning & Sending ---

check_sendable() {
    for d in "$OUTBOUND_DIR"/*/; do
        [ -d "$d" ] || continue
        local status_file="$d/status.json"
        [ -f "$status_file" ] || continue

        local sent_at
        sent_at=$(jq -r '.sent_at // "null"' "$status_file" 2>/dev/null)
        [ "$sent_at" != "null" ] && continue

        local response_count=0
        for f in "$d/responses"/*.json; do
            [ -f "$f" ] && response_count=$((response_count + 1))
        done
        [ "$response_count" -eq 0 ] && continue

        local first_response_at
        first_response_at=$(jq -r '.first_response_at // "null"' "$status_file" 2>/dev/null)
        if [ "$first_response_at" = "null" ]; then
            local tmp
            tmp=$(jq --arg t "$(date -Iseconds)" '.first_response_at = $t' "$status_file")
            echo "$tmp" > "$status_file"
            log "First response for $(basename "$d"), waiting ${SEND_DELAY}s for others"
            continue
        fi

        local first_ts
        first_ts=$(date -d "$first_response_at" +%s 2>/dev/null) || continue
        local now
        now=$(date +%s)
        local elapsed=$((now - first_ts))

        if [ "$elapsed" -lt "$SEND_DELAY" ]; then
            continue
        fi

        assemble_and_send "$d"
    done
}

# --- Assembly and Sending ---

assemble_and_send() {
    local email_dir="$1"
    local status_file="$email_dir/status.json"
    local responses_dir="$email_dir/responses"

    local primary_content=""
    local addon_content=""

    for f in "$responses_dir"/*.json; do
        [ -f "$f" ] || continue
        local rtype
        rtype=$(jq -r '.type' "$f")
        [ "$rtype" = "pass" ] && continue

        local position content
        position=$(jq -r '.position // 99' "$f")
        content=$(jq -r '.content' "$f")

        if [ "$rtype" = "primary" ] || [ "$position" -eq 1 ]; then
            primary_content="$content"
        else
            addon_content+="$content"$'\n\n'
        fi
    done

    local final_body=""
    if [ -n "$primary_content" ]; then
        final_body="$primary_content"
    fi

    if [ -n "$addon_content" ]; then
        if [ -n "$final_body" ]; then
            final_body+=$'\n\n---\nAdditional notes from other sessions:\n\n'"$addon_content"
        else
            final_body="$addon_content"
        fi
    fi

    if [ -z "$final_body" ]; then
        log "No contributions for $(basename "$email_dir"), not sending"
        return
    fi

    local subject=""
    if [ -f "$email_dir/email.json" ]; then
        local orig_subject
        orig_subject=$(jq -r '.subject // ""' "$email_dir/email.json")
        subject="Re: $orig_subject"
    fi
    if [ -f "$email_dir/thread.json" ]; then
        subject=$(jq -r '.subject // ""' "$email_dir/thread.json")
    fi

    local send_response
    send_response=$(curl -s -X POST \
        -H "Authorization: Bearer $INBOX_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg subject "$subject" --arg body "$final_body" \
            '{subject: $subject, body: $body}')" \
        "$INBOX_API_URL/send" 2>/dev/null)

    local send_status
    send_status=$(echo "$send_response" | jq -r '.status // "error"')

    if [ "$send_status" = "sent" ]; then
        log "Email sent for $(basename "$email_dir"): $subject"

        local tmp
        tmp=$(jq --arg t "$(date -Iseconds)" '.assembled_at = $t | .sent_at = $t' "$status_file")
        echo "$tmp" > "$status_file"

        if [ -f "$email_dir/thread.json" ]; then
            local thread_id
            thread_id=$(jq -r '.thread_id' "$email_dir/thread.json")
            cp "$email_dir/thread.json" "$THREAD_DIR/$thread_id.json"
        fi
    else
        log "Failed to send email for $(basename "$email_dir"): $send_response"
    fi
}

# --- Outbound Detection ---

check_outbound() {
    for d in "$OUTBOUND_DIR"/out_*; do
        [ -d "$d" ] || continue
        local status_file="$d/status.json"
        [ -f "$status_file" ] && continue

        local primary_file=""
        for f in "$d/responses"/*.json; do
            [ -f "$f" ] || continue
            local rtype
            rtype=$(jq -r '.type' "$f" 2>/dev/null)
            if [ "$rtype" = "primary" ]; then
                primary_file="$f"
                break
            fi
        done

        [ -z "$primary_file" ] && continue

        local from_pid
        from_pid=$(jq -r '.pid' "$primary_file")
        log "Outbound email initiated by session $from_pid"

        jq -n \
            --arg email_id "$(basename "$d")" \
            --arg first_response_at "$(date -Iseconds)" \
            '{
                email_id: $email_id,
                direction: "outbound",
                first_response_at: $first_response_at,
                assembled_at: null,
                sent_at: null
            }' > "$status_file"
    done
}

# --- Main Loop ---

main() {
    log "Hubless Teams Watcher starting"
    log "Outbound dir: $OUTBOUND_DIR"
    log "Poll interval: ${POLL_INTERVAL}s"
    log "Send delay: ${SEND_DELAY}s"

    while true; do
        poll_inbox || log "Inbox poll failed"
        check_outbound
        check_sendable
        sleep "$POLL_INTERVAL"
    done
}

main "$@"

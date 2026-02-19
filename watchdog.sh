#!/bin/bash
# Hubless Teams — Watchdog
#
# Monitors heartbeat files for agent tmux sessions.
# When a session is idle AND there are pending work items,
# injects a wake-up message via tmux send-keys.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

OPERATOR_AWAY_FLAG="/tmp/hubless-operator-away"

mkdir -p "$HEARTBEAT_DIR"

log() {
    echo "[watchdog $(date -Iseconds)] $*" >&2
}

find_agent_sessions() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "${SESSION_MATCH}" || true
}

find_claude_pid_in_session() {
    local session="$1"
    local pane_pid
    pane_pid=$(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null | head -1)
    [ -z "$pane_pid" ] && return

    ps --ppid "$pane_pid" -o pid=,comm= 2>/dev/null | while read -r pid comm; do
        if [ "$comm" = "claude" ]; then
            echo "$pid"
            return
        fi
        ps --ppid "$pid" -o pid=,comm= 2>/dev/null | while read -r cpid ccomm; do
            if [ "$ccomm" = "claude" ]; then
                echo "$cpid"
                return
            fi
        done
    done
}

is_stale() {
    local file="$1"
    local threshold="$2"
    [ ! -f "$file" ] && return 0
    local file_time
    file_time=$(stat -c %Y "$file" 2>/dev/null) || return 0
    local now
    now=$(date +%s)
    local age=$(( now - file_time ))
    [ "$age" -gt "$threshold" ]
}

find_pending_items() {
    for d in "$OUTBOUND_DIR"/*/; do
        [ -d "$d" ] || continue
        local status_file="$d/status.json"
        [ -f "$status_file" ] || continue
        local sent_at
        sent_at=$(jq -r '.sent_at // "null"' "$status_file" 2>/dev/null)
        [ "$sent_at" != "null" ] && continue
        [ -f "$d/email.json" ] || continue
        local subject
        subject=$(jq -r '.subject // "(no subject)"' "$d/email.json" 2>/dev/null)
        echo "${d}|${subject}"
    done
}

wake_session() {
    local session="$1"
    local message="$2"
    log "Waking session '$session'"
    tmux send-keys -t "$session" C-c 2>/dev/null || true
    sleep 0.5
    tmux send-keys -t "$session" -l "$message" 2>/dev/null || {
        log "Failed to send keys to session '$session'"
        return 1
    }
    tmux send-keys -t "$session" Enter 2>/dev/null
    log "Wake message sent to '$session'"
}

check_operator_away() {
    local most_recent=0
    local now
    now=$(date +%s)
    for hb in "$HEARTBEAT_DIR"/user-*; do
        [ -f "$hb" ] || continue
        local hb_time
        hb_time=$(stat -c %Y "$hb" 2>/dev/null) || continue
        [ "$hb_time" -gt "$most_recent" ] && most_recent="$hb_time"
    done
    if [ "$most_recent" -eq 0 ]; then
        return 0
    fi
    local age=$(( now - most_recent ))
    [ "$age" -gt "$OPERATOR_AWAY_THRESHOLD" ]
}

notify_operator_away() {
    local sessions="$1"
    local most_recent=0
    local now
    now=$(date +%s)
    for hb in "$HEARTBEAT_DIR"/user-*; do
        [ -f "$hb" ] || continue
        local hb_time
        hb_time=$(stat -c %Y "$hb" 2>/dev/null) || continue
        [ "$hb_time" -gt "$most_recent" ] && most_recent="$hb_time"
    done
    local away_min=$(( (now - most_recent) / 60 ))
    for session in $sessions; do
        wake_session "$session" "[hub $(date -u +%H:%M\ UTC)] Operator appears away (no activity for ${away_min}min)."
    done
}

log "Hubless Teams Watchdog starting"
log "Monitoring tmux sessions matching: ${SESSION_MATCH}"
log "Idle threshold: ${IDLE_THRESHOLD}s"
log "Check interval: ${CHECK_INTERVAL}s"

while true; do
    sessions=$(find_agent_sessions)

    if [ -z "$sessions" ]; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    pending=$(find_pending_items)

    for session in $sessions; do
        claude_pid=$(find_claude_pid_in_session "$session")
        [ -z "$claude_pid" ] && continue

        user_heartbeat="$HEARTBEAT_DIR/user-${claude_pid}"

        if ! is_stale "$user_heartbeat" "$IDLE_THRESHOLD"; then
            continue
        fi

        if [ -z "$pending" ]; then
            continue
        fi

        user_age=0
        if [ -f "$user_heartbeat" ]; then
            file_time=$(stat -c %Y "$user_heartbeat" 2>/dev/null) || file_time=$(date +%s)
            user_age=$(( ($(date +%s) - file_time) / 60 ))
        else
            user_age="unknown"
        fi

        email_count=0
        while IFS='|' read -r dir subject; do
            email_count=$((email_count + 1))
        done <<< "$pending"

        if [ "$email_count" -eq 1 ]; then
            subject=$(echo "$pending" | head -1 | cut -d'|' -f2)
            dir=$(echo "$pending" | head -1 | cut -d'|' -f1)
            message="[hub $(date -u +%H:%M\ UTC)] New email (subject: ${subject}). Operator idle ${user_age}min. Dir: ${dir} — Read email.json and respond with: SIXEL_PID=${claude_pid} bash ${HUB_DIR}/respond.sh contribute ${dir} \"your response\""
        else
            message="[hub $(date -u +%H:%M\ UTC)] ${email_count} pending emails. Operator idle ${user_age}min. Check ${OUTBOUND_DIR}/ for unsent emails."
        fi

        wake_session "$session" "$message"
    done

    # Operator away detection (one-shot with feedback-loop protection)
    if check_operator_away; then
        if [ ! -f "$OPERATOR_AWAY_FLAG" ]; then
            log "Operator appears away — notifying sessions"
            notify_operator_away "$sessions"
            touch "$OPERATOR_AWAY_FLAG"
        fi
    else
        if [ -f "$OPERATOR_AWAY_FLAG" ]; then
            flag_time=$(stat -c %Y "$OPERATOR_AWAY_FLAG" 2>/dev/null) || flag_time=0
            most_recent_hb=0
            for hb in "$HEARTBEAT_DIR"/user-*; do
                [ -f "$hb" ] || continue
                hb_time=$(stat -c %Y "$hb" 2>/dev/null) || continue
                [ "$hb_time" -gt "$most_recent_hb" ] && most_recent_hb="$hb_time"
            done
            # Grace period: only clear flag if heartbeat is >5min newer than flag.
            # This prevents the feedback loop where tmux injection refreshes the
            # heartbeat and immediately clears the away flag.
            if [ "$most_recent_hb" -gt $(( flag_time + 300 )) ]; then
                log "Operator is back — clearing away flag"
                rm -f "$OPERATOR_AWAY_FLAG"
            fi
        fi
    fi

    sleep "$CHECK_INTERVAL"
done

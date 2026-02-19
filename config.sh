#!/bin/bash
# Hubless Teams — Configuration
#
# All scripts source this file. Edit these values for your setup.
# Alternatively, set them as environment variables before starting.

# --- Required: where this repo lives ---
HUB_DIR="${HUB_DIR:-$HOME/hubless-teams}"

# --- Required: your email API ---
# Your inbox API key. DO NOT commit the real value — use an env var.
INBOX_API_KEY="${INBOX_API_KEY:?Set INBOX_API_KEY environment variable}"
INBOX_API_URL="${INBOX_API_URL:?Set INBOX_API_URL environment variable (e.g. https://your-email-api.example.com/v1)}"

# --- Paths (derived from HUB_DIR, usually no need to change) ---
STATE_DIR="${HUB_DIR}/state"
OUTBOUND_DIR="${STATE_DIR}/outbound"
THREAD_DIR="${STATE_DIR}/threads"
SEEN_FILE="${STATE_DIR}/seen-ids"
PEERS_FILE="${STATE_DIR}/peers.json"
CHAT_DIR="${HUB_DIR}/chat"
MSG_DIR="${CHAT_DIR}/messages"
LOG_FILE="${CHAT_DIR}/log.md"
MANIFEST_DIR="/tmp/hubless-manifests"
HEARTBEAT_DIR="/tmp/hubless-heartbeats"
LOCK_FILE="/tmp/hubless-started"

# --- Tuning ---
POLL_INTERVAL="${POLL_INTERVAL:-60}"          # seconds between inbox polls
SEND_DELAY="${SEND_DELAY:-120}"               # seconds after first response before sending
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"        # seconds between watchdog checks
IDLE_THRESHOLD="${IDLE_THRESHOLD:-300}"        # seconds before a session is considered idle
OPERATOR_AWAY_THRESHOLD="${OPERATOR_AWAY_THRESHOLD:-1800}"  # seconds before "operator away" alert

# --- Session matching ---
# The watchdog only monitors tmux sessions whose name contains this string.
# Set this to something unique to your agent sessions.
SESSION_MATCH="${SESSION_MATCH:-agent}"

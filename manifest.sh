#!/bin/bash
# Sixel Teams — Manifest Writer
#
# Writes a manifest file identifying the current session.
# Usage: ./manifest.sh [project_dir]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

mkdir -p "$MANIFEST_DIR"

sixel_manifest_pid() {
    echo "$PPID"
}

sixel_manifest_write() {
    local project_dir="${1:-$(pwd)}"
    local pid
    pid=$(sixel_manifest_pid)
    local manifest_file="$MANIFEST_DIR/manifest-${pid}"

    cat > "$manifest_file" <<EOF
pid: ${pid}
project: ${project_dir}
updated: $(date -Iseconds)
EOF
}

sixel_manifest_cleanup() {
    for f in "$MANIFEST_DIR"/manifest-*; do
        [ -f "$f" ] || continue
        local pid
        pid=$(basename "$f" | sed 's/manifest-//')
        if ! kill -0 "$pid" 2>/dev/null; then
            rm "$f"
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    sixel_manifest_write "$1"
fi

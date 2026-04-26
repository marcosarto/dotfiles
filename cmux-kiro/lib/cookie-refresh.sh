#!/bin/bash
# Background cookie refresher for cmux browser panels.
# Polls ~/.midway/cookie mtime and re-injects into tracked browser surfaces.
# Usage: lib/cookie-refresh.sh <state_dir> <socket_path>

set +e
source "$(dirname "$0")/auth.sh"

STATE_DIR="$1"
SOCK="${2:-/tmp/cmux.sock}"
POLL_INTERVAL=30

export CMUX_SOCKET_PATH="$SOCK"
mkdir -p "$STATE_DIR" 2>/dev/null
echo $$ > "$STATE_DIR/cookie_pid"

_get_mtime() { stat -f "%m" "$COOKIE_FILE" 2>/dev/null || echo "0"; }

_inject_surface() {
    local surface="$1" url="$2"
    cmux tree --all 2>/dev/null | grep -q "$surface" || return 1

    local cookies_json
    cookies_json=$(_sso_cookies_json "$url") || return 1

    printf '{"id":"r","method":"browser.cookies.set","params":{"surface_id":"%s","cookies":%s}}\n' \
        "$surface" "$cookies_json" | nc -w 2 -U "$SOCK" >/dev/null 2>&1
    cmux browser "$surface" reload >/dev/null 2>&1
}

_inject_all() {
    [ -f "$STATE_DIR/browser_surfaces" ] || return 0
    local alive=""
    while IFS=$'\t' read -r surface url; do
        [ -n "$surface" ] || continue
        if _inject_surface "$surface" "$url"; then
            alive="$alive$surface\t$url"$'\n'
        fi
    done < "$STATE_DIR/browser_surfaces"
    printf "%b" "$alive" > "$STATE_DIR/browser_surfaces"
}

LAST_MTIME=$(cat "$STATE_DIR/cookie_mtime" 2>/dev/null || echo "0")
while true; do
    sleep "$POLL_INTERVAL"
    [ -S "$SOCK" ] || exit 0
    [ -f "$COOKIE_FILE" ] || continue
    MTIME=$(_get_mtime)
    if [ "$MTIME" != "$LAST_MTIME" ]; then
        _inject_all
        LAST_MTIME="$MTIME"
        echo "$LAST_MTIME" > "$STATE_DIR/cookie_mtime"
    fi
done

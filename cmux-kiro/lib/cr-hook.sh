#!/bin/bash
# cr-hook.sh — update cmux sidebar with a CR pill
# Called by cr-wrapper.sh (shell wrapper) and hooks/pre-cr
# Usage: cr-hook.sh CR-12345678
set +e

CR_ID="$1"
[ -n "$CR_ID" ] || exit 0
[ -n "$CMUX_SOCKET_PATH" ] && [ -S "$CMUX_SOCKET_PATH" ] || exit 0

WS="$CMUX_WORKSPACE_ID"
TAB="$CMUX_TAB_ID"
[ -n "$WS" ] || exit 0

STATE_DIR="/tmp/kiro-cmux-$WS"
mkdir -p "$STATE_DIR" 2>/dev/null

echo "$CR_ID" > "$STATE_DIR/cr_id"
URL="https://code.amazon.com/reviews/$CR_ID"
echo "set_status cr $CR_ID --icon=arrow.triangle.branch --color=#0a84ff --url=$URL --tab=$TAB" \
    | nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1
exit 0

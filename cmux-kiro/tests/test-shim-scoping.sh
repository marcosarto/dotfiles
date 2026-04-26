#!/bin/bash
# Tests for cmux-shim workspace scoping.
# Verifies: --tab injection for scoped commands, notify_target defaulting from env vars.

PASS=0 FAIL=0
SHIM="$(cd "$(dirname "$0")/.." && pwd)/lib/remote/cmux-shim"

assert() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $label"
        ((PASS++)) || true
    else
        echo "  ✗ $label"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        ((FAIL++)) || true
    fi
}

# We can't send to a real socket, so we patch send() to just print the message.
# This tests the CLI→socket translation logic without needing cmux running.
run_shim() {
    CMUX_SOCKET_PATH=/tmp/fake.sock \
    CMUX_WORKSPACE_ID="${TEST_WS:-}" \
    CMUX_TAB_ID="${TEST_TAB:-}" \
    CMUX_SURFACE_ID="${TEST_SURFACE:-}" \
    python3 -c "
import sys, os
sys.argv = ['cmux'] + sys.argv[1:]
# Patch send() to capture the message instead of sending to socket
import types
exec(open('$SHIM').read().replace(
    'result = send(msg)',
    'print(\"MSG:\" + msg); result = \"OK\"'
))
" "$@" 2>/dev/null | grep "^MSG:" | sed 's/^MSG://'
}

echo "=== Workspace scoping for generic commands ==="

# set-status should get --tab injected
TEST_WS="ws-123" TEST_TAB="" TEST_SURFACE=""
msg=$(run_shim set-status kiro working --icon brain --color "#ff9500")
assert "set-status gets --tab from CMUX_WORKSPACE_ID" \
    'set_status kiro working --icon brain --color #ff9500 --tab=ws-123' "$msg"

# clear-status should get --tab injected
msg=$(run_shim clear-status kiro)
assert "clear-status gets --tab" 'clear_status kiro --tab=ws-123' "$msg"

# log should get --tab injected
msg=$(run_shim log --level info --source kiro "test message")
assert "log gets --tab" 'log --level info --source kiro test message --tab=ws-123' "$msg"

# set-progress should get --tab injected
msg=$(run_shim set-progress 0.5 --label "Building")
assert "set-progress gets --tab" 'set_progress 0.5 --label Building --tab=ws-123' "$msg"

# clear-progress should get --tab injected
msg=$(run_shim clear-progress)
assert "clear-progress gets --tab" 'clear_progress --tab=ws-123' "$msg"

# Falls back to CMUX_TAB_ID if CMUX_WORKSPACE_ID is empty
TEST_WS="" TEST_TAB="tab-456" TEST_SURFACE=""
msg=$(run_shim set-status kiro idle)
assert "falls back to CMUX_TAB_ID" 'set_status kiro idle --tab=tab-456' "$msg"

# No injection when --tab already present
TEST_WS="ws-123" TEST_TAB="" TEST_SURFACE=""
msg=$(run_shim set-status kiro idle --tab=explicit)
assert "no injection when --tab present" 'set_status kiro idle --tab=explicit' "$msg"

# No injection when env vars empty
TEST_WS="" TEST_TAB="" TEST_SURFACE=""
msg=$(run_shim set-status kiro idle)
assert "no injection when env empty" 'set_status kiro idle' "$msg"

# Non-scoped commands should NOT get --tab
TEST_WS="ws-123" TEST_TAB="" TEST_SURFACE=""
msg=$(run_shim tree --all)
assert "tree does not get --tab" 'tree --all' "$msg"

echo ""
echo "=== Notify workspace/surface defaulting ==="

# notify with explicit --workspace and --surface
TEST_WS="" TEST_TAB="" TEST_SURFACE=""
msg=$(run_shim notify --title "T" --body "B" --workspace ws-1 --surface sf-1)
assert "explicit workspace+surface → notify_target" 'notify_target ws-1 sf-1 T||B' "$msg"

# notify with --workspace only, surface from env
TEST_WS="" TEST_TAB="" TEST_SURFACE="sf-env"
msg=$(run_shim notify --title "T" --body "B" --workspace ws-1)
assert "workspace explicit, surface from env → notify_target" 'notify_target ws-1 sf-env T||B' "$msg"

# notify with neither, both from env
TEST_WS="ws-env" TEST_TAB="" TEST_SURFACE="sf-env"
msg=$(run_shim notify --title "T" --body "B")
assert "both from env → notify_target" 'notify_target ws-env sf-env T||B' "$msg"

# notify with no workspace/surface anywhere → plain notify
TEST_WS="" TEST_TAB="" TEST_SURFACE=""
msg=$(run_shim notify --title "T" --body "B")
assert "no workspace/surface → plain notify" 'notify T||B' "$msg"

# ── Summary ─────────────────────────────────────────────────

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1

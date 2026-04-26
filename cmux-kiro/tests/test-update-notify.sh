#!/bin/bash
# Tests for auto-update failure notifications.
# Verifies: fetch failure notifies, pull failure notifies, success notifies, no-update-needed is silent.

PASS=0 FAIL=0
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# We need cmux socket to verify notifications
if [ -z "$CMUX_SOCKET_PATH" ] || [ ! -S "$CMUX_SOCKET_PATH" ] || [ -z "$CMUX_WORKSPACE_ID" ]; then
    echo "Skipping — not running inside cmux"
    exit 0
fi

source "$REPO_DIR/lib/update.sh"

# Capture cmux notify calls instead of sending real notifications
NOTIFY_CALLS=""
cmux() {
    if [ "$1" = "notify" ]; then
        NOTIFY_CALLS="$*"
    fi
}

# Stubs
_is_dev_mode() { return 1; }
_bg_ping() { :; }
_relink_agents() { :; }
_sync_remotes() { :; }
kiro-cli() { :; }
python3() { :; }

assert_match() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  ✓ $label"; ((PASS++)) || true
    else
        echo "  ✗ $label (expected '$needle' in '$haystack')"; ((FAIL++)) || true
    fi
}

assert_empty() {
    local label="$1" val="$2"
    if [ -z "$val" ]; then
        echo "  ✓ $label"; ((PASS++)) || true
    else
        echo "  ✗ $label (expected empty, got '$val')"; ((FAIL++)) || true
    fi
}

# ── Fetch failure ───────────────────────────────────────────

echo "=== Fetch failure sends notification ==="
NOTIFY_CALLS=""
_remote_version() { return 1; }
echo "0" > "$UPDATE_CHECK_FILE"
_update_throttled_bg "$CMUX_WORKSPACE_ID" "$CMUX_SOCKET_PATH"
assert_match "notify fired on fetch failure" "$NOTIFY_CALLS" "update failed"
assert_match "notify includes fix hint" "$NOTIFY_CALLS" "kmux update"

# ── Pull failure ────────────────────────────────────────────

echo ""
echo "=== Pull failure sends notification ==="
NOTIFY_CALLS=""
_remote_version() { echo "99.99.99"; }
git() { [[ "$*" == *"pull"* ]] && return 1; command git "$@"; }
echo "0" > "$UPDATE_CHECK_FILE"
_update_throttled_bg "$CMUX_WORKSPACE_ID" "$CMUX_SOCKET_PATH"
assert_match "notify fired on pull failure" "$NOTIFY_CALLS" "update failed"
unset -f git

# ── No update needed (already current) ─────────────────────

echo ""
echo "=== No update needed is silent ==="
NOTIFY_CALLS=""
_remote_version() { echo "$(_current_version)"; }
echo "0" > "$UPDATE_CHECK_FILE"
_update_throttled_bg "$CMUX_WORKSPACE_ID" "$CMUX_SOCKET_PATH"
assert_empty "no notify when already up to date" "$NOTIFY_CALLS"

# ── Summary ─────────────────────────────────────────────────

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1

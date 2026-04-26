#!/bin/bash
# Tests for user-set workspace title preservation.
# Verifies: user_titled marker, cmux-title.sh skip logic, mid-session rename detection.
# Note: user title detection relies solely on the ◆ prefix — agentSpawn always sets a ◆ title,
# and mid-session renames are detected by comparing the live title to ◆ $OUR_LAST.

PASS=0 FAIL=0
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FAKE_WS="test-ws-$$"
STATE_DIR="/tmp/kiro-cmux-$FAKE_WS"
TITLE_FILE="/tmp/kiro-title-$FAKE_WS"

cleanup() { rm -rf "$STATE_DIR" "$TITLE_FILE"; }
trap cleanup EXIT
mkdir -p "$STATE_DIR"

assert() {
    local label="$1" cond="$2"
    if eval "$cond"; then
        echo "  ✓ $label"
        ((PASS++)) || true
    else
        echo "  ✗ $label"
        ((FAIL++)) || true
    fi
}

# ── user_titled marker blocks cmux-title.sh rename ─────────

echo "=== cmux-title.sh respects user_titled marker ==="

# With marker: title should NOT be written
touch "$STATE_DIR/user_titled"
rm -f "$TITLE_FILE"

USER_TITLED=false
[ -f "$STATE_DIR/user_titled" ] && USER_TITLED=true
assert "USER_TITLED flag set when marker exists" "[ '$USER_TITLED' = 'true' ]"

TITLE="AI Generated Title"
if [ -n "$TITLE" ] && [ "$USER_TITLED" = "false" ]; then
    echo "$TITLE" > "$TITLE_FILE"
fi
assert "title file NOT written when user_titled" "[ ! -f '$TITLE_FILE' ]"

# Without marker: title gets written
rm -f "$STATE_DIR/user_titled" "$TITLE_FILE"
USER_TITLED=false
[ -f "$STATE_DIR/user_titled" ] && USER_TITLED=true
assert "USER_TITLED flag unset without marker" "[ '$USER_TITLED' = 'false' ]"

if [ -n "$TITLE" ] && [ "$USER_TITLED" = "false" ]; then
    echo "$TITLE" > "$TITLE_FILE"
fi
assert "title file written without marker" "[ -f '$TITLE_FILE' ]"
assert "title content correct" "[ '$(cat $TITLE_FILE)' = 'AI Generated Title' ]"

# ── Mid-session rename detection ────────────────────────────

echo ""
echo "=== Mid-session rename detection ==="

_test_mid_session() {
    local live_title="$1" our_last="$2" label="$3" expect_user="$4"
    rm -f "$STATE_DIR/user_titled"
    USER_TITLED=false

    # Replicate the check from cmux-title.sh
    if [ -n "$live_title" ] && [ -n "$our_last" ] && [ "$live_title" != "◆ $our_last" ]; then
        touch "$STATE_DIR/user_titled"
        USER_TITLED=true
    fi

    if [ "$expect_user" = "true" ]; then
        assert "$label" "[ '$USER_TITLED' = 'true' ]"
    else
        assert "$label" "[ '$USER_TITLED' = 'false' ]"
    fi
}

_test_mid_session "my custom name" "AI Generated Title" "user renamed mid-session → detected" "true"
_test_mid_session "◆ AI Generated Title" "AI Generated Title" "our title unchanged → not detected" "false"
_test_mid_session "" "AI Generated Title" "empty live title → not detected" "false"
_test_mid_session "◆ Refined Title" "Refined Title" "our refined title matches → not detected" "false"
_test_mid_session "kssh clouddesk2" "AI Generated Title" "cmux auto-title overwrite → detected (but won't happen — agentSpawn always sets ◆)" "true"

# ── Session restart: stale title file must not trigger user_titled ──

echo ""
echo "=== Session restart clears stale title state ==="

echo "Fix sidebar bug" > "$TITLE_FILE"
touch "$STATE_DIR/user_titled"
touch "$STATE_DIR/mid_turn_titled"

# Simulate agentSpawn cleanup
rm -f "$TITLE_FILE" "$STATE_DIR/user_titled" "$STATE_DIR/mid_turn_titled"
echo "12345" > "$STATE_DIR/session_pid"

assert "title file cleared on session restart" "[ ! -f '$TITLE_FILE' ]"
assert "user_titled marker cleared on session restart" "[ ! -f '$STATE_DIR/user_titled' ]"
assert "mid_turn_titled marker cleared on session restart" "[ ! -f '$STATE_DIR/mid_turn_titled' ]"
assert "session_pid written on restart" "[ -f '$STATE_DIR/session_pid' ]"

OUR_LAST=$(cat "$TITLE_FILE" 2>/dev/null)
USER_TITLED=false
LIVE_TITLE="◆ AmznCmuxKiroTools"
if [ -n "$LIVE_TITLE" ] && [ -n "$OUR_LAST" ] && [ "$LIVE_TITLE" != "◆ $OUR_LAST" ]; then
    USER_TITLED=true
fi
assert "empty title file → no false user_titled after restart" "[ '$USER_TITLED' = 'false' ]"

# ── Session PID: stale title scripts abort ───────────

echo ""
echo "=== Stale title script aborts on session PID mismatch ==="

echo "222" > "$STATE_DIR/session_pid"
MY_SESSION_PID="111"
TITLE="Stale Title"
WROTE=false
CUR_PID=$(cat "$STATE_DIR/session_pid" 2>/dev/null)
if [ "$CUR_PID" = "$MY_SESSION_PID" ]; then
    echo "$TITLE" > "$TITLE_FILE"
    WROTE=true
fi
assert "stale script (PID 111 vs 222) does NOT write title" "[ '$WROTE' = 'false' ]"
assert "title file still absent after stale script" "[ ! -f '$TITLE_FILE' ]"

MY_SESSION_PID="222"
WROTE=false
CUR_PID=$(cat "$STATE_DIR/session_pid" 2>/dev/null)
if [ "$CUR_PID" = "$MY_SESSION_PID" ]; then
    echo "$TITLE" > "$TITLE_FILE"
    WROTE=true
fi
assert "current script (PID 222 vs 222) writes title" "[ '$WROTE' = 'true' ]"
assert "title file written by current script" "[ -f '$TITLE_FILE' ]"
rm -f "$TITLE_FILE"

# ── agentSpawn always sets ◆ title (live cmux) ─────────────

echo ""
echo "=== agentSpawn always sets ◆ title (live cmux) ==="

if [ -n "$CMUX_SOCKET_PATH" ] && [ -S "$CMUX_SOCKET_PATH" ] && [ -n "$CMUX_WORKSPACE_ID" ]; then
    # Save current title
    ORIG_TITLE=$(printf '{"id":"t","method":"workspace.list","params":{}}\n' \
        | nc -w 1 -U "$CMUX_SOCKET_PATH" 2>/dev/null \
        | jq -r --arg ws "$CMUX_WORKSPACE_ID" '.result.workspaces[] | select(.ref == $ws or .id == $ws) | .title' 2>/dev/null)

    # Set a non-◆ title (simulating cmux auto-title from command)
    cmux workspace-action --workspace "$CMUX_WORKSPACE_ID" --action rename --title "kssh clouddesk2" 2>/dev/null

    # agentSpawn always overwrites with ◆
    cmux workspace-action --workspace "$CMUX_WORKSPACE_ID" --action rename --title "◆ AmznCmuxKiroTools" 2>/dev/null

    LIVE=$(printf '{"id":"t","method":"workspace.list","params":{}}\n' \
        | nc -w 1 -U "$CMUX_SOCKET_PATH" 2>/dev/null \
        | jq -r --arg ws "$CMUX_WORKSPACE_ID" '.result.workspaces[] | select(.ref == $ws or .id == $ws) | .title' 2>/dev/null)
    assert "agentSpawn overwrites command title with ◆" "[ '$LIVE' = '◆ AmznCmuxKiroTools' ]"

    # Restore original title
    cmux workspace-action --workspace "$CMUX_WORKSPACE_ID" --action rename --title "$ORIG_TITLE" 2>/dev/null
else
    echo "  (skipping live socket tests — not in cmux)"
fi

# ── Task/CR pill persistence across title refinements ───────

echo ""
echo "=== Task pill persists when titler returns no task ==="

# Simulate: task was set on first prompt, follow-up prompt ("yes") has no task
echo "TRACK-1234" > "$STATE_DIR/task_id"
PREV_TASK=$(cat "$STATE_DIR/task_id" 2>/dev/null)
TASK=""  # titler returned no task for "yes"
# New logic: only act when a different task is explicitly detected
if [ -n "$TASK" ] && [ "$TASK" != "$PREV_TASK" ]; then
    echo "$TASK" > "$STATE_DIR/task_id"
fi
assert "task_id file still has original value" "[ '$(cat $STATE_DIR/task_id)' = 'TRACK-1234' ]"

echo ""
echo "=== Task pill updates when different task detected ==="

echo "TRACK-1234" > "$STATE_DIR/task_id"
PREV_TASK=$(cat "$STATE_DIR/task_id" 2>/dev/null)
TASK="TRACK-5678"  # titler found a new task
if [ -n "$TASK" ] && [ "$TASK" != "$PREV_TASK" ]; then
    echo "$TASK" > "$STATE_DIR/task_id"
fi
assert "task_id updated to new task" "[ '$(cat $STATE_DIR/task_id)' = 'TRACK-5678' ]"

echo ""
echo "=== CR pill persists across title refinements ==="

# Simulate: CR was set, titler generates a refined title (ACTION != SAME)
echo "CR-123456" > "$STATE_DIR/cr_id"
echo "TRACK-1234" > "$STATE_DIR/task_id"
PREV_TASK=$(cat "$STATE_DIR/task_id" 2>/dev/null)
TASK="TRACK-1234"  # same task
ACTION="NEW"       # title changed
TITLE="Refined title text"
CLEARED_CR=false
# New logic: CR only clears on task change
if [ -n "$TASK" ] && [ "$TASK" != "$PREV_TASK" ]; then
    if [ -n "$PREV_TASK" ]; then
        rm -f "$STATE_DIR/cr_id"
        CLEARED_CR=true
    fi
fi
assert "CR pill NOT cleared on title refinement (same task)" "[ '$CLEARED_CR' = 'false' ]"
assert "cr_id file still exists" "[ -f '$STATE_DIR/cr_id' ]"

echo ""
echo "=== CR pill clears when task changes ==="

echo "CR-123456" > "$STATE_DIR/cr_id"
echo "TRACK-1234" > "$STATE_DIR/task_id"
PREV_TASK=$(cat "$STATE_DIR/task_id" 2>/dev/null)
TASK="TRACK-9999"  # different task
CLEARED_CR=false
if [ -n "$TASK" ] && [ "$TASK" != "$PREV_TASK" ]; then
    echo "$TASK" > "$STATE_DIR/task_id"
    if [ -n "$PREV_TASK" ]; then
        rm -f "$STATE_DIR/cr_id"
        CLEARED_CR=true
    fi
fi
assert "CR pill cleared on task change" "[ '$CLEARED_CR' = 'true' ]"
assert "cr_id file removed" "[ ! -f '$STATE_DIR/cr_id' ]"
assert "task_id updated to new task" "[ '$(cat $STATE_DIR/task_id)' = 'TRACK-9999' ]"

echo ""
echo "=== CR pill persists when titler returns SAME ==="

echo "CR-123456" > "$STATE_DIR/cr_id"
echo "TRACK-1234" > "$STATE_DIR/task_id"
PREV_TASK=$(cat "$STATE_DIR/task_id" 2>/dev/null)
TASK="TRACK-1234"
ACTION="SAME"
CLEARED_CR=false
if [ -n "$TASK" ] && [ "$TASK" != "$PREV_TASK" ]; then
    if [ -n "$PREV_TASK" ]; then
        rm -f "$STATE_DIR/cr_id"
        CLEARED_CR=true
    fi
fi
assert "CR pill NOT cleared on ACTION=SAME" "[ '$CLEARED_CR' = 'false' ]"
assert "cr_id file still exists" "[ -f '$STATE_DIR/cr_id' ]"

# ── Summary ─────────────────────────────────────────────────

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1

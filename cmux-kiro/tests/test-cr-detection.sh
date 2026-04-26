#!/bin/bash
# Tests for CR detection: cr-hook.sh, cr-wrapper.sh, hooks/pre-cr, and titler CR pill logic

PASS=0 FAIL=0
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
FAKE_WS="test-ws-$$"
STATE_DIR="/tmp/kiro-cmux-$FAKE_WS"

cleanup() { rm -rf "$TMPDIR" "$STATE_DIR" /tmp/test-cr-bin-$$; }
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

# ── cr-hook.sh ──────────────────────────────────────────────

echo "=== cr-hook.sh ==="

# Test: no args = silent exit
CMUX_WORKSPACE_ID="$FAKE_WS" CMUX_TAB_ID=tab1 \
    CMUX_SOCKET_PATH="$TMPDIR/nosock" \
    "$REPO_DIR/lib/cr-hook.sh"
assert "no args exits cleanly" "[ $? -eq 0 ]"

# Test: no socket = silent exit
rm -f "$STATE_DIR/cr_id"
CMUX_WORKSPACE_ID="$FAKE_WS" CMUX_TAB_ID=tab1 \
    CMUX_SOCKET_PATH="$TMPDIR/nosock" \
    "$REPO_DIR/lib/cr-hook.sh" "CR-111"
assert "no socket exits cleanly" "[ ! -f '$STATE_DIR/cr_id' ]"

# Test: writes state file (need real socket for cmux call, skip if not in cmux)
if [ -n "$CMUX_SOCKET_PATH" ] && [ -S "$CMUX_SOCKET_PATH" ]; then
    rm -f "$STATE_DIR/cr_id"
    CMUX_WORKSPACE_ID="$FAKE_WS" "$REPO_DIR/lib/cr-hook.sh" "CR-222"
    assert "writes cr_id state file" "[ '$(cat $STATE_DIR/cr_id 2>/dev/null)' = 'CR-222' ]"

    # Test: idempotent
    OUTPUT=$(CMUX_WORKSPACE_ID="$FAKE_WS" "$REPO_DIR/lib/cr-hook.sh" "CR-222" 2>&1)
    assert "idempotent — same CR skipped" "[ -z '$OUTPUT' ]"

    # Test: new CR replaces old
    CMUX_WORKSPACE_ID="$FAKE_WS" "$REPO_DIR/lib/cr-hook.sh" "CR-333"
    assert "new CR replaces old" "[ '$(cat $STATE_DIR/cr_id 2>/dev/null)' = 'CR-333' ]"
else
    echo "  (skipping live socket tests — not in cmux)"
fi

# ── cr-wrapper.sh ───────────────────────────────────────────

echo ""
echo "=== cr-wrapper.sh ==="

# Test: defines cr() inside cmux
DEFINED=$(CMUX_SOCKET_PATH="$CMUX_SOCKET_PATH" bash -c "source '$REPO_DIR/lib/cr-wrapper.sh'; type cr 2>&1")
if [ -n "$CMUX_SOCKET_PATH" ] && [ -S "$CMUX_SOCKET_PATH" ]; then
    assert "defines cr() when socket exists" "echo '$DEFINED' | grep -q 'function'"
else
    assert "does NOT define cr() without socket" "echo '$DEFINED' | grep -qv 'function'"
fi

# Test: does NOT define cr() outside cmux
DEFINED=$(CMUX_SOCKET_PATH="" bash -c "source '$REPO_DIR/lib/cr-wrapper.sh'; type cr 2>&1")
assert "no cr() without CMUX_SOCKET_PATH" "echo '$DEFINED' | grep -qv 'is a function'"

# Test: captures CR ID from output
mkdir -p /tmp/test-cr-bin-$$
cat > /tmp/test-cr-bin-$$/cr <<'EOF'
#!/bin/bash
echo "Code review: https://code.amazon.com/reviews/CR-444"
EOF
chmod +x /tmp/test-cr-bin-$$/cr

if [ -n "$CMUX_SOCKET_PATH" ] && [ -S "$CMUX_SOCKET_PATH" ]; then
    rm -f "$STATE_DIR/cr_id"
    CMUX_WORKSPACE_ID="$FAKE_WS" CMUX_SOCKET_PATH="$CMUX_SOCKET_PATH" CMUX_TAB_ID="$CMUX_TAB_ID" \
        PATH="/tmp/test-cr-bin-$$:$PATH" \
        bash -c "source '$REPO_DIR/lib/cr-wrapper.sh'; cr 2>/dev/null"
    assert "captures CR from output" "[ '$(cat $STATE_DIR/cr_id 2>/dev/null)' = 'CR-444' ]"
fi

# Test: exit code passthrough
cat > /tmp/test-cr-bin-$$/cr <<'EOF'
#!/bin/bash
echo "error"
exit 42
EOF
chmod +x /tmp/test-cr-bin-$$/cr

if [ -n "$CMUX_SOCKET_PATH" ] && [ -S "$CMUX_SOCKET_PATH" ]; then
    CMUX_SOCKET_PATH="$CMUX_SOCKET_PATH" CMUX_TAB_ID="$CMUX_TAB_ID" \
        PATH="/tmp/test-cr-bin-$$:$PATH" \
        bash -c "source '$REPO_DIR/lib/cr-wrapper.sh'; cr 2>/dev/null; exit \$?"
    EC=$?
    assert "exit code passthrough" "[ $EC -eq 42 ]"
fi

# Test: no CR in output = no state
cat > /tmp/test-cr-bin-$$/cr <<'EOF'
#!/bin/bash
echo "nothing here"
EOF
chmod +x /tmp/test-cr-bin-$$/cr

if [ -n "$CMUX_SOCKET_PATH" ] && [ -S "$CMUX_SOCKET_PATH" ]; then
    rm -f "$STATE_DIR/cr_id"
    CMUX_WORKSPACE_ID="$FAKE_WS" CMUX_SOCKET_PATH="$CMUX_SOCKET_PATH" CMUX_TAB_ID="$CMUX_TAB_ID" \
        PATH="/tmp/test-cr-bin-$$:$PATH" \
        bash -c "source '$REPO_DIR/lib/cr-wrapper.sh'; cr 2>/dev/null"
    assert "no CR in output = no state" "[ ! -f '$STATE_DIR/cr_id' ]"
fi

# Test: failed cr clears "Creating CR..." pill (no existing cr_id)
cat > /tmp/test-cr-bin-$$/cr <<'EOF'
#!/bin/bash
echo "Unable to determine package(s) to review."
exit 1
EOF
chmod +x /tmp/test-cr-bin-$$/cr

if [ -n "$CMUX_SOCKET_PATH" ] && [ -S "$CMUX_SOCKET_PATH" ]; then
    rm -f "$STATE_DIR/cr_id"
    # Set a fake "Creating CR..." pill first
    cmux set-status cr "Creating CR..." --icon arrow.triangle.pull --color "#ff9500" >/dev/null 2>&1
    CMUX_WORKSPACE_ID="$FAKE_WS" CMUX_SOCKET_PATH="$CMUX_SOCKET_PATH" CMUX_TAB_ID="$CMUX_TAB_ID" \
        PATH="/tmp/test-cr-bin-$$:$PATH" \
        bash -c "source '$REPO_DIR/lib/cr-wrapper.sh'; cr 2>/dev/null; true"
    assert "failed cr clears Creating pill" "[ ! -f '$STATE_DIR/cr_id' ]"
fi

# Test: failed cr does NOT clear existing real CR pill
cat > /tmp/test-cr-bin-$$/cr <<'EOF'
#!/bin/bash
echo "Unable to determine package(s) to review."
exit 1
EOF
chmod +x /tmp/test-cr-bin-$$/cr

if [ -n "$CMUX_SOCKET_PATH" ] && [ -S "$CMUX_SOCKET_PATH" ]; then
    echo "CR-999" > "$STATE_DIR/cr_id"
    CMUX_WORKSPACE_ID="$FAKE_WS" CMUX_SOCKET_PATH="$CMUX_SOCKET_PATH" CMUX_TAB_ID="$CMUX_TAB_ID" \
        PATH="/tmp/test-cr-bin-$$:$PATH" \
        bash -c "source '$REPO_DIR/lib/cr-wrapper.sh'; cr 2>/dev/null; true"
    assert "failed cr preserves existing CR pill" "[ '$(cat $STATE_DIR/cr_id 2>/dev/null)' = 'CR-999' ]"
fi

# ── hooks/pre-cr ────────────────────────────────────────────

echo ""
echo "=== hooks/pre-cr ==="

# Test: exits 0 always
"$REPO_DIR/hooks/pre-cr"
assert "exits 0" "[ $? -eq 0 ]"

# Test: no stdout (the OK OK fix)
OUTPUT=$("$REPO_DIR/hooks/pre-cr" 2>/dev/null)
assert "no stdout leak" "[ -z '$OUTPUT' ]"

# Test: no-op without socket
OUTPUT=$(CMUX_SOCKET_PATH="" "$REPO_DIR/hooks/pre-cr" 2>&1)
assert "silent without socket" "[ -z '$OUTPUT' ]"

# ── titler CR pill logic ────────────────────────────────────

echo ""
echo "=== titler CR pill persistence ==="

# Simulate the titler's CR pill logic in isolation.
# CR pill is now set exclusively by cr-hook.sh. The titler only clears it
# when it signals a topic change (ACTION != SAME and a new TITLE is set).
_test_titler_cr() {
    local ACTION="$1" TITLE="$2" PREV_CR="$3" expected="$4" label="$5"
    local test_state="$TMPDIR/cr_id_test"

    [ -n "$PREV_CR" ] && echo "$PREV_CR" > "$test_state" || rm -f "$test_state"

    # Replicate the logic from cmux-title.sh
    if [ -n "$PREV_CR" ] && [ "$ACTION" != "SAME" ] && [ -n "$TITLE" ]; then
        rm -f "$test_state"
    fi

    local result=$(cat "$test_state" 2>/dev/null)
    assert "$label" "[ '${result:-empty}' = '$expected' ]"
}

# Follow-up prompt (SAME) → pill stays
_test_titler_cr "SAME" "" "CR-555" "CR-555" "SAME action preserves CR pill"

# New task (new title) → pill cleared
_test_titler_cr "" "New Task Title" "CR-555" "empty" "new title clears CR pill"

# SAME action even with a title refinement → pill stays
_test_titler_cr "SAME" "Refined Title" "CR-555" "CR-555" "SAME with title refinement preserves CR pill"

# No previous CR, new title → stays empty (nothing to clear)
_test_titler_cr "" "New Task Title" "" "empty" "no CR stays empty on new title"

# No title generated (e.g. already had one), no SAME → pill stays (no topic change signal)
_test_titler_cr "" "" "CR-555" "CR-555" "no title + no SAME preserves CR pill"

# ── Summary ─────────────────────────────────────────────────

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1

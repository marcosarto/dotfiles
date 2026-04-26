#!/bin/bash
# Tests that userPromptSubmit immediately replaces the stale activity pill
# (Waiting/Done/Error) with a "Working: <description>" state.

PASS=0 FAIL=0
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
FAKE_WS="test-ws-$$"
STATE_DIR="/tmp/kiro-cmux-$FAKE_WS"
export CMUX_LOG="$TMPDIR/cmux-calls.log"

cleanup() { rm -rf "$TMPDIR" "$STATE_DIR"; }
trap cleanup EXIT
mkdir -p "$STATE_DIR" "$TMPDIR/bin"

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

# Create fake Unix socket
FAKE_SOCK="$TMPDIR/cmux.sock"
python3 -c "
import socket, threading, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind('$FAKE_SOCK')
s.listen(5)
s.settimeout(10)
def accept_loop():
    while True:
        try:
            c, _ = s.accept()
            c.sendall(b'OK\n')
            c.close()
        except: break
threading.Thread(target=accept_loop, daemon=True).start()
time.sleep(10)
" &
SOCK_PID=$!
sleep 0.3

# Stub cmux CLI — logs all calls
cat > "$TMPDIR/bin/cmux" << 'STUB'
#!/bin/bash
echo "$@" >> "$CMUX_LOG"
STUB
chmod +x "$TMPDIR/bin/cmux"

# Stub background scripts — no-op
for f in cmux-title.sh cmux-summarize-notify.sh; do
    echo '#!/bin/bash' > "$TMPDIR/bin/$f"
    chmod +x "$TMPDIR/bin/$f"
done
echo '#!/bin/bash' > "$TMPDIR/bin/nc"
chmod +x "$TMPDIR/bin/nc"

run_hook() {
    local event_json="$1"
    echo "$event_json" | \
        CMUX_SOCKET_PATH="$FAKE_SOCK" \
        CMUX_WORKSPACE_ID="$FAKE_WS" \
        CMUX_TAB_ID="tab-$$" \
        CMUX_PANEL_ID="panel-$$" \
        CMUX_SURFACE_ID="surface-$$" \
        PATH="$TMPDIR/bin:$PATH" \
        "$REPO_DIR/hooks/cmux-notify.sh" 2>/dev/null
}

# ── Test: preserves previous activity description ───────────

echo "=== Activity pill reset preserves description ==="

# Simulate previous turn's activity
echo "Implementing auth refresh" > "$STATE_DIR/last_activity"

> "$CMUX_LOG"
run_hook '{"hook_event_name":"userPromptSubmit","prompt":"Fix the token expiry bug","cwd":"/tmp/test"}'
sleep 0.5

assert "pill shows Working: <prev description>" \
    "grep -q 'set-status activity Working: Implementing auth refresh' '$CMUX_LOG'"

assert "uses brain icon" \
    "grep 'set-status activity Working:' '$CMUX_LOG' | grep -q 'brain'"

assert "uses orange color" \
    "grep 'set-status activity Working:' '$CMUX_LOG' | grep -q '#ff9500'"

# ── Test: fallback when no previous activity ────────────────

echo ""
echo "=== Fallback with no previous activity ==="

rm -f "$STATE_DIR/last_activity" "$STATE_DIR/prev_activity"

> "$CMUX_LOG"
run_hook '{"hook_event_name":"userPromptSubmit","prompt":"Hello","cwd":"/tmp/test"}'
sleep 0.5

assert "falls back to Working: thinking" \
    "grep -q 'set-status activity Working: thinking' '$CMUX_LOG'"

# ── Test: not clearing — replacing ──────────────────────────

echo ""
echo "=== Replaces (not clears) stale pill ==="

assert "no clear-status activity call" \
    "! grep -q 'clear-status activity' '$CMUX_LOG'"

# ── Cleanup ─────────────────────────────────────────────────

kill $SOCK_PID 2>/dev/null
wait $SOCK_PID 2>/dev/null

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

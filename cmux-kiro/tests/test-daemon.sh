#!/bin/bash
# Smoke tests for kask daemon mode

PASS=0 FAIL=0
KASK="python3 $HOME/bin/kiro-acp-client.py"

pass() { echo "✓ $1"; ((PASS++)) || true; }
fail() { echo "✗ $1"; ((FAIL++)) || true; }

echo "=== kask daemon smoke tests ==="

# Clean slate
$KASK --stop 2>/dev/null
sleep 1

# 1. First call auto-starts daemon and returns a response
OUT=$($KASK "Reply with only the word: hello" 2>/dev/null)
if echo "$OUT" | grep -qi "hello"; then
    pass "first call (cold start) returns response"
else
    fail "first call returned: $OUT"
fi

# 2. Daemon socket exists after first call
if [ -S /tmp/kask/fast.sock ]; then
    pass "daemon socket exists"
else
    fail "daemon socket missing"
fi

# 3. PID file exists and process is alive
PID=$(cat /tmp/kask/fast.pid 2>/dev/null)
if kill -0 "$PID" 2>/dev/null; then
    pass "daemon process alive (pid $PID)"
else
    fail "daemon process not running"
fi

# 4. Second call (warm) returns a response
OUT=$($KASK "Reply with only the word: world" 2>/dev/null)
if echo "$OUT" | grep -qi "world"; then
    pass "second call (warm) returns response"
else
    fail "second call returned: $OUT"
fi

# 5. Per-agent isolation — cmux-titler gets its own socket
OUT=$(KASK_AGENT=cmux-titler $KASK "Title this task: fix the login bug" 2>/dev/null)
if [ -S /tmp/kask/cmux-titler.sock ]; then
    pass "cmux-titler daemon gets its own socket"
else
    fail "cmux-titler socket missing"
fi

# 6. kask --stop cleans up
$KASK --stop 2>/dev/null
sleep 1
if [ ! -S /tmp/kask/fast.sock ] && [ ! -S /tmp/kask/cmux-titler.sock ]; then
    pass "--stop removes sockets"
else
    fail "--stop did not remove sockets"
fi
if ! kill -0 "$PID" 2>/dev/null; then
    pass "--stop kills daemon process"
else
    fail "daemon still running after --stop"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# Test that kask daemon recovers after the ACP subprocess dies mid-session.
# This is the exact failure mode where titler/notifier stop working until restart.

PASS=0 FAIL=0
KASK="python3 $HOME/bin/kiro-acp-client.py"
AGENT="test-recovery"

pass() { echo "✓ $1"; ((PASS++)) || true; }
fail() { echo "✗ $1"; ((FAIL++)) || true; }

echo "=== kask daemon recovery tests ==="

# Clean slate
KASK_AGENT=$AGENT $KASK --stop 2>/dev/null
sleep 1

# 1. Warm up the daemon with a successful call
OUT=$(KASK_AGENT=$AGENT $KASK "Reply with only the word: alpha" 2>/dev/null)
if echo "$OUT" | grep -qi "alpha"; then
    pass "initial call works"
else
    fail "initial call returned: $OUT"
fi

DAEMON_PID=$(cat /tmp/kask/$AGENT.pid 2>/dev/null)

# 2. Kill the ACP subprocess (kiro-cli) inside the daemon — simulates mid-session death
# The daemon stays alive, but its client is now broken
ACP_PIDS=$(pgrep -P "$DAEMON_PID" 2>/dev/null)
if [ -z "$ACP_PIDS" ]; then
    # kiro-cli runs in its own process group — find by agent name
    ACP_PIDS=$(pgrep -f "kiro-cli.*acp.*--agent.*$AGENT" 2>/dev/null | grep -v "^$DAEMON_PID$")
fi

if [ -n "$ACP_PIDS" ]; then
    echo "$ACP_PIDS" | xargs kill -9 2>/dev/null
    sleep 1
    pass "killed ACP subprocess(es): $ACP_PIDS"
else
    fail "could not find ACP subprocess to kill"
    KASK_AGENT=$AGENT $KASK --stop 2>/dev/null
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# 3. Daemon should still be alive (it's the ACP child that died, not the daemon)
if kill -0 "$DAEMON_PID" 2>/dev/null; then
    pass "daemon still alive after ACP kill"
else
    fail "daemon died (unexpected)"
fi

# 4. Next call should recover — daemon detects dead client, spawns new one
OUT=$(KASK_AGENT=$AGENT $KASK "Reply with only the word: beta" 2>/dev/null)
if echo "$OUT" | grep -qi "beta"; then
    pass "call after ACP kill recovered and returned response"
else
    # This is the actual bug — before the fix, this would return empty
    fail "call after ACP kill returned: '${OUT:-<empty>}'"
fi

# 5. Verify it's not just a one-off — second post-recovery call works too
OUT=$(KASK_AGENT=$AGENT $KASK "Reply with only the word: gamma" 2>/dev/null)
if echo "$OUT" | grep -qi "gamma"; then
    pass "second post-recovery call works"
else
    fail "second post-recovery call returned: '${OUT:-<empty>}'"
fi

# Cleanup
KASK_AGENT=$AGENT $KASK --stop 2>/dev/null

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

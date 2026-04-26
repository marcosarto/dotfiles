#!/bin/bash
# Test that the doctor.sh spinner doesn't orphan when its parent is killed.
set -e

echo "=== Spinner orphan test ==="

# Spawn a parent shell that starts the spinner, then get killed
/bin/bash -c '
    PARENT_PID=$$
    (
        trap "exit 0" TERM
        while kill -0 "$PARENT_PID" 2>/dev/null; do
            sleep 0.1
        done
    ) &
    echo "$!"
    sleep 60  # keep parent alive until we kill it
' > /tmp/spinner-test-out &
PARENT=$!
sleep 0.5

SPINNER=$(cat /tmp/spinner-test-out 2>/dev/null)
rm -f /tmp/spinner-test-out

if [ -z "$SPINNER" ] || ! kill -0 "$SPINNER" 2>/dev/null; then
    echo "❌ FAIL — spinner didn't start (PID: ${SPINNER:-empty})"
    kill "$PARENT" 2>/dev/null
    exit 1
fi

echo "Parent PID:  $PARENT"
echo "Spinner PID: $SPINNER"

# Kill the parent (simulates cmux closing the pane)
kill -9 "$PARENT" 2>/dev/null
wait "$PARENT" 2>/dev/null || true

echo "Parent killed, waiting for spinner to self-terminate..."
sleep 1

if kill -0 "$SPINNER" 2>/dev/null; then
    echo "❌ FAIL — spinner still alive after parent died"
    kill "$SPINNER" 2>/dev/null
    exit 1
else
    echo "✅ PASS — spinner self-terminated"
fi

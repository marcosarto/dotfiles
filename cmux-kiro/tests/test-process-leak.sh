#!/bin/bash
# Test that kask doesn't leak processes when kiro-cli acp is broken.
set -e

FAKE_BIN=$(mktemp -d)
trap 'rm -rf "$FAKE_BIN"; PATH="$FAKE_BIN:$PATH" python3 ~/bin/kiro-acp-client.py --stop 2>/dev/null; true' EXIT

# Fake kiro-cli that exits immediately (simulates broken ACP)
cat > "$FAKE_BIN/kiro-cli" << 'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$FAKE_BIN/kiro-cli"

# Stop any test daemons
PATH="$FAKE_BIN:$PATH" KASK_AGENT=test-leak python3 ~/bin/kiro-acp-client.py --stop 2>/dev/null || true
sleep 0.5

BEFORE=$(pgrep -f 'kiro-cli.*acp' 2>/dev/null | wc -l | tr -d ' ')

echo "Running 5 kask calls with broken kiro-cli..."
for i in $(seq 1 5); do
    # No timeout needed — daemon returns ERROR fast, caller exits on ERROR
    PATH="$FAKE_BIN:$PATH" KASK_AGENT=test-leak python3 ~/bin/kiro-acp-client.py "hello" 2>/dev/null || true
    echo "  call $i done"
done

sleep 3
AFTER=$(pgrep -f 'kiro-cli.*acp' 2>/dev/null | wc -l | tr -d ' ')
LEAKED=$((AFTER - BEFORE))

echo ""
echo "=== Results ==="
echo "Processes before: $BEFORE"
echo "Processes after:  $AFTER"
echo "Leaked:           $LEAKED"

if [ "$LEAKED" -eq 0 ]; then
    echo "✅ PASS — no process leak"
else
    echo "❌ FAIL — leaked $LEAKED processes"
    pgrep -af 'kiro-cli.*acp' || true
fi

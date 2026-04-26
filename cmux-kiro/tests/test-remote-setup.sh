#!/bin/bash
# Tests that remote setup scripts install steering files and all agent configs.
# Validates setup-remote.sh and setup-remote-push.sh have parity with setup.sh.

PASS=0 FAIL=0
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)

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

echo "=== Remote setup parity checks ==="

# --- Steering file ---
echo ""
echo "--- Steering file installation ---"

assert "setup-remote.sh installs steering file" \
    'grep -q "cmux-kiro-usage.md" "$REPO_DIR/lib/remote/setup-remote.sh" && grep -q "kiro/steering" "$REPO_DIR/lib/remote/setup-remote.sh"'

assert "setup-remote-push.sh installs steering file" \
    'grep -q "cmux-kiro-usage.md" "$REPO_DIR/lib/remote/setup-remote-push.sh" && grep -q "kiro/steering" "$REPO_DIR/lib/remote/setup-remote-push.sh"'

assert "steering/cmux-kiro-usage.md exists in repo" \
    '[ -f "$REPO_DIR/steering/cmux-kiro-usage.md" ]'

# --- Agent configs ---
echo ""
echo "--- Agent config installation ---"

# All agents that doctor.sh checks for should be installed by all setup scripts
EXPECTED_AGENTS="cmux-titler.json cmux-notifier.json cmux-activity.json fast.json"

for agent in $EXPECTED_AGENTS; do
    assert "setup.sh installs $agent" \
        'grep -q "$agent" "$REPO_DIR/setup.sh"'

    assert "setup-remote.sh installs $agent" \
        'grep -q "$agent" "$REPO_DIR/lib/remote/setup-remote.sh"'

    assert "setup-remote-push.sh installs $agent" \
        'grep -q "$agent" "$REPO_DIR/lib/remote/setup-remote-push.sh"'

    assert "$agent exists in repo" \
        '[ -f "$REPO_DIR/agents/$agent" ]'
done

# --- Shell aliases ---
echo ""
echo "--- Shell alias installation ---"

assert "setup.sh installs k alias" \
    'grep -q "alias k=" "$REPO_DIR/setup.sh"'

assert "setup-remote.sh installs k alias" \
    'grep -q "alias k=" "$REPO_DIR/lib/remote/setup-remote.sh"'

assert "setup-remote-push.sh installs k alias" \
    'grep -q "alias k=" "$REPO_DIR/lib/remote/setup-remote-push.sh"'

assert "setup.sh installs kask alias" \
    'grep -q "kiro-acp-client.py" "$REPO_DIR/setup.sh" && grep -q "kask" "$REPO_DIR/setup.sh"'

assert "setup-remote.sh installs kask alias" \
    'grep -q "kiro-acp-client.py" "$REPO_DIR/lib/remote/setup-remote.sh" && grep -q "kask" "$REPO_DIR/lib/remote/setup-remote.sh"'

assert "setup-remote-push.sh installs kask alias" \
    'grep -q "kiro-acp-client.py" "$REPO_DIR/lib/remote/setup-remote-push.sh" && grep -q "kask" "$REPO_DIR/lib/remote/setup-remote-push.sh"'

# --- Doctor parity ---
echo ""
echo "--- Doctor parity ---"

# Every agent that doctor.sh checks should be in all setup scripts
DOCTOR_AGENTS=$(grep -oE 'cmux-[a-z]+\.json' "$REPO_DIR/doctor.sh" 2>/dev/null | sort -u)
for agent in $DOCTOR_AGENTS; do
    # Skip cmux.json — it's generated from template, not symlinked
    [ "$agent" = "cmux.json" ] && continue
    assert "doctor-checked $agent is in setup-remote.sh" \
        'grep -q "$agent" "$REPO_DIR/lib/remote/setup-remote.sh"'
    assert "doctor-checked $agent is in setup-remote-push.sh" \
        'grep -q "$agent" "$REPO_DIR/lib/remote/setup-remote-push.sh"'
done

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1

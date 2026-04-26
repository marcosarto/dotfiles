#!/bin/bash
# Tests for postToolUse event parsing across old CLI and new TUI formats.
# Ensures _tool_response_text() extracts content from both payload structures.

PASS=0 FAIL=0
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/hooks/cmux-notify.sh"

# Extract _tool_response_text from the hook script
eval "$(sed -n '/^_tool_response_text()/,/^}/p' "$SCRIPT")"

assert() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $label"
        ((PASS++)) || true
    else
        echo "  ✗ $label (expected '$expected', got '$actual')"
        ((FAIL++)) || true
    fi
}

# ── _tool_response_text: New TUI format ────────────────────

echo "=== New TUI format (.tool_response.items[]) ==="

# Shell tool: Json item
EVENT='{"tool_response":{"items":[{"Json":{"exit_status":"exit status: 0","stdout":"hello world\n","stderr":""}}]}}'
RESULT=$(_tool_response_text "$EVENT")
assert "Json item extracts content" "true" "$(echo "$RESULT" | grep -q 'hello world' && echo true || echo false)"

# Write tool: Text item
EVENT='{"tool_response":{"items":[{"Text":"Successfully replaced 1 occurrence(s) in foo.sh."}]}}'
RESULT=$(_tool_response_text "$EVENT")
assert "Text item extracts content" "Successfully replaced 1 occurrence(s) in foo.sh." "$RESULT"

# CR in shell output
EVENT='{"tool_response":{"items":[{"Json":{"exit_status":"exit status: 0","stdout":"Running pre-cr hook\nCR created: https://code.amazon.com/reviews/CR-267291791/revisions/1\n","stderr":""}}]}}'
CR=$(_tool_response_text "$EVENT" | grep -oE 'CR-[0-9]+' | head -1)
assert "CR detected from Json item" "CR-267291791" "$CR"

# Multiple items
EVENT='{"tool_response":{"items":[{"Text":"line one"},{"Text":"line two"}]}}'
RESULT=$(_tool_response_text "$EVENT")
assert "multiple Text items joined" "line one
line two" "$RESULT"

# ── _tool_response_text: Old CLI format ─────────────────────

echo ""
echo "=== Old CLI format (.tool_response.result) ==="

# Result as array of objects (actual old CLI format)
EVENT='{"tool_response":{"success":true,"result":[{"exit_status":"0","stdout":"CR created: CR-267042453\n","stderr":""}]}}'
CR=$(_tool_response_text "$EVENT" | grep -oE 'CR-[0-9]+' | head -1)
assert "CR detected from .result array" "CR-267042453" "$CR"

# Result as string (docs example)
EVENT='{"tool_response":{"success":true,"result":["# Hooks\n\nHooks allow you to execute..."]}}'
RESULT=$(_tool_response_text "$EVENT")
assert ".result string array extracts" "true" "$(echo "$RESULT" | grep -q 'Hooks' && echo true || echo false)"

# Error response
EVENT='{"tool_response":{"success":false,"error":"command not found"}}'
RESULT=$(_tool_response_text "$EVENT")
assert "error response returns empty" "" "$RESULT"

# ── Edge cases ──────────────────────────────────────────────

echo ""
echo "=== Edge cases ==="

# Empty tool_response
EVENT='{"tool_response":{}}'
RESULT=$(_tool_response_text "$EVENT")
assert "empty tool_response returns empty" "" "$RESULT"

# Missing tool_response entirely
EVENT='{"tool_name":"shell"}'
RESULT=$(_tool_response_text "$EVENT")
assert "missing tool_response returns empty" "" "$RESULT"

# Empty items array
EVENT='{"tool_response":{"items":[]}}'
RESULT=$(_tool_response_text "$EVENT")
assert "empty items returns empty" "" "$RESULT"

# ── Summary ─────────────────────────────────────────────────

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1

#!/bin/bash
# Tests that the activity agent doesn't leak context between workspaces.
#
# The kask daemon keeps a persistent ACP session (conversation history) shared
# across all callers. If workspace A asks about "auth refresh" and workspace B
# then asks a vague prompt like "yes do it", the model might reference A's task
# in B's activity — leaking cross-workspace context.
#
# This test sends two distinct-topic prompts (simulating two workspaces) through
# the same daemon, then checks that the second response doesn't reference the
# first workspace's topic.

PASS=0 FAIL=0

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

# Build the activity prompt the same way cmux-summarize-notify.sh does
build_activity_prompt() {
    local prev="$1" prompt="$2"
    echo "IMPORTANT: Each request is independent. Do NOT reference any previous requests or responses in this conversation.

Generate a short present-tense activity description for what this AI assistant is working on.

${prev:+Previous task: $prev
}User asked: $prompt

RULES:
- Present tense, describing the objective of this task
- HARD LIMIT: 30 characters maximum. This is strict — count carefully.
- Omit filenames, paths, and details to stay under 30 chars
- Prefer short verbs: Fix, Add, Update, Research, Implement, Check
- If the user prompt is ONLY a confirmation word (yes, ok, do it, go ahead, sure) with no other content, use the \"Previous task\" field above. If there is no \"Previous task\" field either, respond with {\"activity\":\"\"}
- Any prompt that asks a question or describes a task is NOT a confirmation — always generate an activity for it
- Examples: \"Implementing auth refresh\", \"Fixing auth module tests\", \"Researching SIM-1234\", \"Checking jq version\"

Respond with ONLY: {\"activity\":\"...\"}"
}

parse_activity() {
    echo "$1" | sed 's/```json//; s/```//' | tr '\n' ' ' | grep -o '{[^}]*}' | head -1 | jq -r '.activity // empty' 2>/dev/null
}

echo "=== Activity cross-workspace leak test ==="
echo ""
echo "This test checks whether the shared kask daemon leaks conversation"
echo "context between workspaces. Two simulated workspaces send prompts"
echo "about completely different topics through the same daemon."
echo ""

# ── Workspace A: distinctive topic ──────────────────────────
# Use a very specific, unusual topic so we can detect leakage
WS_A_TOPIC="fix the Kubernetes HPA autoscaler"
WS_A_PROMPT=$(build_activity_prompt "" "$WS_A_TOPIC")

echo "Workspace A prompt: $WS_A_TOPIC"
RAW_A=$(KASK_AGENT=cmux-activity python3 ~/bin/kiro-acp-client.py "$WS_A_PROMPT" 2>/dev/null)
ACTIVITY_A=$(parse_activity "$RAW_A")
echo "Workspace A activity: $ACTIVITY_A"
echo ""

# ── Workspace B: completely different topic ─────────────────
# This workspace has its own prev_activity and prompt — no relation to A
WS_B_TOPIC="write unit tests for the email parser"
WS_B_PROMPT=$(build_activity_prompt "" "$WS_B_TOPIC")

echo "Workspace B prompt: $WS_B_TOPIC"
RAW_B=$(KASK_AGENT=cmux-activity python3 ~/bin/kiro-acp-client.py "$WS_B_PROMPT" 2>/dev/null)
ACTIVITY_B=$(parse_activity "$RAW_B")
echo "Workspace B activity: $ACTIVITY_B"
echo ""

# ── Check: B should not reference A's topic ─────────────────
# Lowercase for case-insensitive matching
ACTIVITY_B_LOWER=$(echo "$ACTIVITY_B" | tr '[:upper:]' '[:lower:]')

assert "B does not mention 'kubernetes'" \
    "[[ ! \"\$ACTIVITY_B_LOWER\" == *kubernetes* ]]"

assert "B does not mention 'hpa'" \
    "[[ ! \"\$ACTIVITY_B_LOWER\" == *hpa* ]]"

assert "B does not mention 'autoscal'" \
    "[[ ! \"\$ACTIVITY_B_LOWER\" == *autoscal* ]]"

# B should reference its own topic (email/parser/test)
assert "B references its own topic (email, parser, or test)" \
    "[[ \"\$ACTIVITY_B_LOWER\" == *email* || \"\$ACTIVITY_B_LOWER\" == *pars* || \"\$ACTIVITY_B_LOWER\" == *test* ]]"

# ── Workspace B2: vague follow-up with B's own prev_activity ──
# This is the most likely leak scenario: a vague prompt like "yes do it"
# where the model might pull from conversation history (A's topic) instead
# of the provided prev_activity context
echo "--- Vague follow-up test ---"
echo ""

WS_B2_PROMPT=$(build_activity_prompt "$ACTIVITY_B" "yes, do it")

echo "Workspace B follow-up prompt: 'yes, do it' (prev: $ACTIVITY_B)"
RAW_B2=$(KASK_AGENT=cmux-activity python3 ~/bin/kiro-acp-client.py "$WS_B2_PROMPT" 2>/dev/null)
ACTIVITY_B2=$(parse_activity "$RAW_B2")
echo "Workspace B follow-up activity: $ACTIVITY_B2"
echo ""

ACTIVITY_B2_LOWER=$(echo "$ACTIVITY_B2" | tr '[:upper:]' '[:lower:]')

assert "B follow-up does not mention 'kubernetes'" \
    "[[ ! \"\$ACTIVITY_B2_LOWER\" == *kubernetes* ]]"

assert "B follow-up does not mention 'hpa'" \
    "[[ ! \"\$ACTIVITY_B2_LOWER\" == *hpa* ]]"

assert "B follow-up does not mention 'autoscal'" \
    "[[ ! \"\$ACTIVITY_B2_LOWER\" == *autoscal* ]]"

# ── Workspace C: vague prompt with NO prev_activity ─────────
# Worst case: no prev_activity at all, vague prompt. The model's only
# "context" is conversation history from A and B — any reference to
# either topic is a leak.
echo "--- No-context vague prompt test ---"
echo ""

WS_C_PROMPT=$(build_activity_prompt "" "ok go ahead")

echo "Workspace C prompt: 'ok go ahead' (no prev_activity)"
RAW_C=$(KASK_AGENT=cmux-activity python3 ~/bin/kiro-acp-client.py "$WS_C_PROMPT" 2>/dev/null)
ACTIVITY_C=$(parse_activity "$RAW_C")
echo "Workspace C activity: $ACTIVITY_C"
echo ""

ACTIVITY_C_LOWER=$(echo "$ACTIVITY_C" | tr '[:upper:]' '[:lower:]')

# Empty is the ideal outcome — means the pill won't update (no leak possible)
if [ -z "$ACTIVITY_C" ]; then
    echo "  ✓ C returned empty activity (pill won't update — no leak)"
    ((PASS++)) || true
else
    assert "C does not mention 'kubernetes'" \
        "[[ ! \"\$ACTIVITY_C_LOWER\" == *kubernetes* ]]"

    assert "C does not mention 'email'" \
        "[[ ! \"\$ACTIVITY_C_LOWER\" == *email* ]]"

    assert "C does not mention 'parser'" \
        "[[ ! \"\$ACTIVITY_C_LOWER\" == *pars* ]]"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

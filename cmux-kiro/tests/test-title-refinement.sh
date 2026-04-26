#!/bin/bash
# Reproduces: vague prompt gets generic title, then stop-time refinement
# should improve it but may return SAME instead.
#
# Simulates the two-phase title flow:
#   1. userPromptSubmit: title from raw prompt only (no context)
#   2. stop: re-title with screen_context showing what the task actually was

set +e
PASS=0 FAIL=0

_parse() {
  echo "$1" | sed 's/```json//; s/```//' | tr '\n' ' ' | grep -o '{[^}]*}' | head -1
}

# Phase 1: initial title from vague prompt (simulates userPromptSubmit)
phase1_title() {
  local prompt="$1"
  local msg="Title this task:
Prompt: $prompt"
  RAW=$(KASK_AGENT=cmux-titler python3 ~/bin/kiro-acp-client.py "$msg" 2>/dev/null)
  JSON=$(_parse "$RAW")
  echo "$JSON" | jq -r '.title // empty' 2>/dev/null
}

# Phase 2: refinement with screen context (simulates stop)
phase2_refine() {
  local current_title="$1" prompt="$2" screen="$3"
  local msg="Current title: $current_title
New prompt: $prompt
Assistant response: $screen
If the assistant response reveals what the task is actually about, output a better title. A title that just contains a ticket ID (like \"Fix SIM-12345\" or \"Plan CMUX-8\") is NOT descriptive — replace it with what the work is. Only output SAME if the title already describes the work."
  RAW=$(KASK_AGENT=cmux-titler python3 ~/bin/kiro-acp-client.py "$msg" 2>/dev/null)
  JSON=$(_parse "$RAW")
  ACTION=$(echo "$JSON" | jq -r '.action // empty' 2>/dev/null)
  TITLE=$(echo "$JSON" | jq -r '.title // empty' 2>/dev/null)
  TASK=$(echo "$JSON" | jq -r '.task // empty' 2>/dev/null)
  echo "$ACTION|$TITLE|$TASK"
}

test_scenario() {
  local label="$1" prompt="$2" screen="$3" expect="$4"
  echo ""
  echo "--- $label ---"

  # Phase 1
  TITLE1=$(phase1_title "$prompt")
  echo "  Phase 1 (prompt only): \"$TITLE1\""

  # Phase 2
  RESULT=$(phase2_refine "$TITLE1" "$prompt" "$screen")
  ACTION=$(echo "$RESULT" | cut -d'|' -f1)
  TITLE2=$(echo "$RESULT" | cut -d'|' -f2)
  TASK=$(echo "$RESULT" | cut -d'|' -f3)

  if [ "$ACTION" = "SAME" ]; then
    echo "  Phase 2 (with context): SAME — kept \"$TITLE1\""
    if [ "$expect" = "refine" ]; then
      echo "  ✗ FAIL: expected refinement but got SAME"
      ((FAIL++)) || true
    else
      echo "  ✓ PASS: correctly kept title"
      ((PASS++)) || true
    fi
  elif [ -n "$TITLE2" ]; then
    echo "  Phase 2 (with context): refined → \"$TITLE2\" (task=$TASK)"
    if [ "$expect" = "refine" ]; then
      echo "  ✓ PASS: title was refined"
      ((PASS++)) || true
    else
      echo "  ✓ PASS: title changed (acceptable)"
      ((PASS++)) || true
    fi
  else
    echo "  Phase 2: no output"
    echo "  ✗ FAIL: empty response"
    ((FAIL++)) || true
  fi
}

echo "=== Title refinement tests ==="
echo "Tests whether stop-time context improves vague initial titles"

# Scenario 1: The exact bug — "Plan CMUX-8" gets generic title, then task details arrive
test_scenario \
  "Plan task by ID (the reported bug)" \
  "Plan CMUX-8 and store in md" \
  "Task CMUX-8: Add CRUX CLI hooks support to cmux-kiro. Description: Integrate CRUX CLI pre-commit and post-commit hooks so that code reviews created via CRUX automatically update the sidebar CR pill. Acceptance criteria: hook scripts detect cr --new-review output and pin CR-NNNNN to sidebar." \
  "refine"

# Scenario 2: "Fix SIM-12345" — vague, then context reveals it's about auth timeouts
test_scenario \
  "Fix task by ID, context reveals details" \
  "Fix SIM-12345" \
  "SIM-12345: Authentication service returning 504 Gateway Timeout under load. Root cause: connection pool exhaustion in the Redis session store. Fix: increase pool size from 10 to 50 and add circuit breaker." \
  "refine"

# Scenario 3: "Look at this CR" — vague, then context shows it's a payments refactor
test_scenario \
  "Review CR by ID, context reveals scope" \
  "Review CR-99999" \
  "CR-99999 refactors the payment processing pipeline to use async handlers. Changes span 12 files across the payments-core and payments-api packages. Key change: replaces synchronous DynamoDB calls with batch writes." \
  "refine"

# Scenario 4: Already descriptive prompt — should stay SAME
test_scenario \
  "Already descriptive (should keep)" \
  "Debug the Lambda timeout in the auth service caused by cold starts" \
  "I found the issue — the Lambda has a 3-second timeout but cold starts take 4.2 seconds. Increasing to 10 seconds and adding provisioned concurrency." \
  "keep"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

#!/bin/bash
# Smoke test for cmux-titler agent via kask
# Verifies titles, topic-change detection, and task/CR extraction

PASS=0 FAIL=0

_parse() {
  echo "$1" | sed 's/```json//; s/```//' | tr '\n' ' ' | grep -o '{[^}]*}' | head -1
}

check() {
  local prompt="$1"
  RAW=$(KASK_AGENT=cmux-titler python3 ~/bin/kiro-acp-client.py "Title this task: $prompt" 2>/dev/null)
  JSON=$(_parse "$RAW")
  TITLE=$(echo "$JSON" | jq -r '.title // empty' 2>/dev/null)
  WORDS=$(echo "$TITLE" | wc -w | xargs)
  if [ "$WORDS" -ge 2 ] && [ "$WORDS" -le 6 ]; then
    echo "✓ [$WORDS words] $TITLE"
    ((PASS++)) || true
  else
    echo "✗ [$WORDS words] $TITLE"
    echo "  prompt: $prompt"
    ((FAIL++)) || true
  fi
}

check_topic_change() {
  local title1="$1" prompt2="$2" label="$3"
  local msg="Current title: $title1
New prompt: $prompt2
Output SAME if this continues the same task. Output a new title if this is a completely different topic."
  RAW=$(KASK_AGENT=cmux-titler python3 ~/bin/kiro-acp-client.py "$msg" 2>/dev/null)
  JSON=$(_parse "$RAW")
  ACTION=$(echo "$JSON" | jq -r '.action // empty' 2>/dev/null)
  TITLE=$(echo "$JSON" | jq -r '.title // empty' 2>/dev/null)
  if [ "$ACTION" = "SAME" ]; then
    echo "✗ [SAME] should have generated new title — $label"
    echo "  current: $title1 → prompt: $prompt2"
    ((FAIL++)) || true
  elif [ -n "$TITLE" ]; then
    echo "✓ [new] $TITLE — $label"
    ((PASS++)) || true
  else
    echo "✗ [empty] no title or action — $label"
    echo "  raw: $RAW"
    ((FAIL++)) || true
  fi
}

check_same_topic_with_context() {
  local title1="$1" prompt2="$2" screen="$3" label="$4"
  local msg="Current title: $title1
New prompt: $prompt2
Assistant response: $screen
If the assistant response reveals more about the task, output a better title. Only output SAME if the title is already descriptive enough."
  RAW=$(KASK_AGENT=cmux-titler python3 ~/bin/kiro-acp-client.py "$msg" 2>/dev/null)
  JSON=$(_parse "$RAW")
  ACTION=$(echo "$JSON" | jq -r '.action // empty' 2>/dev/null)
  TITLE=$(echo "$JSON" | jq -r '.title // empty' 2>/dev/null)
  if [ "$ACTION" = "SAME" ]; then
    echo "✓ [SAME] kept title — $label"
    ((PASS++)) || true
  elif [ -n "$TITLE" ]; then
    echo "✓ [refined] $TITLE — $label"
    ((PASS++)) || true
  else
    echo "✗ [empty] no title or action — $label"
    echo "  raw: $RAW"
    ((FAIL++)) || true
  fi
}

check_extraction() {
  local prompt="$1" expect_field="$2" expect_val="$3" label="$4"
  RAW=$(KASK_AGENT=cmux-titler python3 ~/bin/kiro-acp-client.py "Title this task: $prompt" 2>/dev/null)
  JSON=$(_parse "$RAW")
  VAL=$(echo "$JSON" | jq -r ".$expect_field" 2>/dev/null)
  if [ "$VAL" = "$expect_val" ]; then
    echo "✓ [$expect_field=$VAL] — $label"
    ((PASS++)) || true
  else
    echo "✗ [$expect_field=$VAL] expected $expect_val — $label"
    ((FAIL++)) || true
  fi
}

echo "=== cmux-titler smoke tests ==="

echo ""
echo "--- Fresh titles ---"
check "Help me debug a failing Lambda function that times out"
check "Can you refactor the auth middleware to use JWT"
check "Write a Python script to parse CSV files"
check "What's the best way to handle errors in Go"
check "Review CR-54321 for the payments service"
check "Fix the flaky integration test in the CI pipeline"
check "Help me understand this SIM-99999 about latency spikes"

echo ""
echo "--- Topic changes (should generate new title) ---"
check_topic_change "README User Message Summary" "What did I eat for dinner last night" "unrelated question"
check_topic_change "Debug Lambda Timeout" "Write unit tests for the auth module" "different task"
check_topic_change "Refactor Auth Middleware" "Help me set up a new S3 bucket" "different domain"
check_topic_change "Fix CI Pipeline Tests" "Explain how DynamoDB streams work" "learning vs fixing"
check_topic_change "Setup S3 Bucket" "Review CR-12345 for the auth service" "infra to code review"
check_topic_change "Write CSV Parser Script" "What is the oncall rotation for my team" "code to ops"

echo ""
echo "--- Same topic with screen context (should return SAME or similar title) ---"
check_same_topic_with_context "Debug Lambda Timeout" "Can you also check the CloudWatch logs for that Lambda" "I checked the CloudWatch logs for the Lambda function and found timeout errors at 15:30 UTC." "follow-up with context"
check_same_topic_with_context "Write CSV Parser" "Add error handling to the CSV parser" "I added try/except blocks around the CSV parsing logic to handle malformed rows gracefully." "iteration with context"
check_same_topic_with_context "Fix CI Pipeline Tests" "Try running the tests again with verbose output" "I re-ran the test suite with --verbose and the flaky test passed this time. Looks like a timing issue." "retry same task"
check_same_topic_with_context "Review Payments CR" "What about the error handling in that PR" "The error handling in the payments CR looks incomplete — missing retry logic for transient DynamoDB errors." "drilling into same review"

echo ""
echo "--- Task/CR extraction ---"
check_extraction "Fix the bug in SIM-12345 about auth failures" "task" "SIM-12345" "SIM ID extraction"
check_extraction "Review CR-67890 for the payments service" "task" "null" "CR IDs are NOT tasks"
check_extraction "Help me write a Python script" "task" "null" "no task ID present"
check_extraction "Work on TRACK-8864 to add retry logic" "task" "TRACK-8864" "TRACK ID extraction"

echo ""
echo "--- CR in screen context should NOT be extracted as task ---"
# Reproduces bug: titler grabs commit hash instead of CR-NNNNN from cr output
CR_SCREEN="Uploading AmznCmuxKiroTools...

 * 7979fd8 - fix: markdown panel pane reuse

Created code review of AmznCmuxKiroTools...

https://code.amazon.com/reviews/CR-260853041/revisions/1"

CR_MSG="Current title: Fix Markdown Panel Reuse
New prompt: create a new CR
Assistant response: $CR_SCREEN
If the assistant response reveals more about the task, output a better title. Only output SAME if the title is already descriptive enough."
RAW=$(KASK_AGENT=cmux-titler python3 ~/bin/kiro-acp-client.py "$CR_MSG" 2>/dev/null)
JSON=$(echo "$RAW" | sed 's/```json//; s/```//' | tr '\n' ' ' | grep -o '{[^}]*}' | head -1)
CR_VAL=$(echo "$JSON" | jq -r '.task // empty' 2>/dev/null)
if [ -z "$CR_VAL" ] || [ "$CR_VAL" = "null" ]; then
    echo "✓ [task=null] — CR correctly NOT extracted as task"
    ((PASS++)) || true
else
    echo "✗ [task=$CR_VAL] expected null — CR should not be a task"
    echo "  raw: $RAW"
    ((FAIL++)) || true
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

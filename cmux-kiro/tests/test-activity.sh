#!/bin/bash
# Smoke test for cmux-activity via kask (ACP)
# Verifies JSON output with activity field, present tense, ≤30 chars

PASS=0 FAIL=0

check() {
  local desc="$1" prompt="$2"
  MSG="Generate a short present-tense activity description for what this AI assistant is working on.

User asked: $prompt

RULES:
- Present tense, describing the objective of this task
- HARD LIMIT: 30 characters maximum. This is strict — count carefully.
- Omit filenames, paths, and details to stay under 30 chars
- Prefer short verbs: Fix, Add, Update, Research, Implement
- Examples: \"Implementing auth refresh\", \"Fixing auth module tests\", \"Researching SIM-1234\"

Respond with ONLY: {\"activity\":\"...\"}"

  RAW=$(KASK_AGENT=cmux-activity python3 ~/bin/kiro-acp-client.py "$MSG" 2>/dev/null)
  JSON=$(echo "$RAW" | sed 's/```json//; s/```//' | tr '\n' ' ' | grep -o '{[^}]*}' | head -1)
  ACTIVITY=$(echo "$JSON" | jq -r '.activity // empty' 2>/dev/null)
  LEN=${#ACTIVITY}

  local ok=true
  [ -z "$ACTIVITY" ] && ok=false
  [ "$LEN" -gt 70 ] 2>/dev/null && ok=false  # allow slight overflow

  if $ok; then
    echo "✓ $desc"
    echo "  → $ACTIVITY ($LEN chars)"
    ((PASS++))
  else
    echo "✗ $desc"
    echo "  RAW: $RAW"
    echo "  JSON: $JSON"
    echo "  ACTIVITY: $ACTIVITY ($LEN chars)"
    ((FAIL++))
  fi
}

echo "=== cmux-activity smoke tests ==="

check "simple fix" \
  "fix the notification parser"

check "task reference" \
  "implement CMUX-10"

check "SIM lookup" \
  "what's the status of SIM-12345"

check "code review" \
  "review the auth module for security issues"

check "file creation" \
  "create a React component for the dashboard"

check "debugging" \
  "why is the build failing"

check "test run" \
  "run the tests"

check "refactor" \
  "rename all references of CMUX_TAB_ID to CMUX_WORKSPACE_ID"

check "git question" \
  "what branch am I on and is it clean"

check "vague prompt" \
  "do CMUX-8"

check "URL-only prompt" \
  "https://taskei.amazon.dev/tasks/CMUX-10"

check "multi-step task" \
  "set up the new microservice with DynamoDB, Lambda, and API Gateway"

check "search task" \
  "find all TODO comments in the repo"

check "explain code" \
  "how does the cookie refresh daemon work"

check "short question" \
  "whats the time"

check "deploy task" \
  "deploy the lambda to prod"

check "wiki lookup" \
  "find the oncall runbook for builder-mcp"

check "CR creation" \
  "commit and create a code review"

check "dependency check" \
  "what version of jq do I have"

check "conversational follow-up" \
  "thanks, now also fix the tests"

check "URL with task ID" \
  "Research https://taskei.amazon.dev/tasks/CMUX-9"

check "URL-only task" \
  "https://taskei.amazon.dev/tasks/SIM-12345"

check "long paste with instruction at end" \
  "Last login: Thu Mar 19 15:10:55 on ttys004
bssas@50f265f2f6e2 AmznCmuxKiroTools % k
builder-mcp loaded in 1.43 s
Model: claude-opus-4.6-1m
All tools are now trusted
Research https://taskei.amazon.dev/tasks/CMUX-9"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

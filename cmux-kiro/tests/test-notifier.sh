#!/bin/bash
# Smoke test for cmux-notifier via kask (ACP)
# Verifies JSON output with title and body fields

PASS=0 FAIL=0

check() {
  local desc="$1" prompt="$2" tools="$3" response="$4"
  MSG="Summarize this AI assistant turn for a desktop notification.

User asked: $prompt
Tools used: ${tools:-none}
${response:+Assistant response: $response}

RULES:
- If the ASSISTANT RESPONSE (not the user's question) ends with a question to the user or offers choices, the body MUST start with \"Waiting:\" followed by the question/choice summary
- If the assistant completed the task and gave an answer, the body MUST include the concrete result (numbers, names, outcomes) — not just describe what tools ran
- Body must be ONE short sentence (under 120 chars)
- Title must be 2-4 words

Respond with ONLY: {\"title\":\"...\",\"body\":\"...\"}"

  RAW=$(KASK_AGENT=cmux-notifier python3 ~/bin/kiro-acp-client.py "$MSG" 2>/dev/null)
  JSON=$(echo "$RAW" | sed 's/```json//; s/```//' | tr '\n' ' ' | grep -o '{[^}]*}' | head -1)
  TITLE=$(echo "$JSON" | jq -r '.title // empty' 2>/dev/null)
  BODY=$(echo "$JSON" | jq -r '.body // empty' 2>/dev/null)
  TITLE_WORDS=$(echo "$TITLE" | wc -w | tr -d ' ')

  local ok=true
  [ -z "$TITLE" ] && ok=false
  [ -z "$BODY" ] && ok=false
  [ "$TITLE_WORDS" -gt 6 ] 2>/dev/null && ok=false

  if $ok; then
    echo "✓ $desc"
    echo "  T: $TITLE | B: $BODY"
    ((PASS++))
  else
    echo "✗ $desc"
    echo "  RAW: $RAW"
    echo "  JSON: $JSON"
    echo "  T: $TITLE | B: $BODY"
    ((FAIL++))
  fi
}

echo "=== cmux-notifier smoke tests ==="
check "simple question (no tools)" \
  "whats the time" \
  "none" \
  "It's currently 3:42 PM PST on Wednesday, March 18th."

check "file edits" \
  "fix the notification parser" \
  "fs_write, fs_write, execute_bash" \
  "Fixed the JSON parsing in cmux-summarize-notify.sh — the regex now handles nested braces correctly. Tests pass."

check "code review" \
  "review the auth module for security issues" \
  "fs_read, fs_read, fs_read, execute_bash" \
  "Found 2 issues in auth.sh: cookie value is not URL-encoded before injection, and the SSO redirect doesn't validate the target domain."

check "debugging" \
  "why is the build failing" \
  "execute_bash, execute_bash, fs_read" \
  "The build fails because setup.sh references jq 1.7 syntax but the CI image has jq 1.6. The --rawfile flag isn't available."

check "create new file" \
  "create a React component for the dashboard" \
  "fs_write, fs_read" \
  "Created src/components/Dashboard.tsx with a summary card grid, status indicators, and responsive layout."

check "count users from CSV" \
  "How many users are in the CSV file?" \
  "shell, shell, shell, shell" \
  "There are 52 unique users in this Slack channel export. 1 poster and 51 from install/join events."

check "waiting for clarification" \
  "refactor the auth module" \
  "fs_read, fs_read" \
  "I see two auth modules: lib/auth.sh (cookie-based SSO) and lib/auth-open.sh (browser opener). Which one should I refactor, or both?"

check "git operations" \
  "what branch am I on and is it clean" \
  "execute_bash, execute_bash" \
  "You're on feature/notifier-fix, 3 commits ahead of mainline. Working tree is dirty — 2 modified files: hooks/cmux-notify.sh and tests/test-notifier.sh."

check "test results" \
  "run the tests" \
  "execute_bash" \
  "All 12 tests passed in 3.4s. No failures or skips."

check "test failures" \
  "run the tests" \
  "execute_bash, execute_bash, fs_read" \
  "4 of 12 tests failed. Failures in test-titler.sh (timeout), test-notifier.sh (bad JSON parse), test-hook-injection.sh (missing agent), and test-cr-detection.sh (regex mismatch)."

check "SIM task lookup" \
  "what's the status of SIM-12345" \
  "ReadInternalWebsites" \
  "SIM-12345 is assigned to bssas, status In Progress, priority P2. Title: Add mTLS support to browser panels. Last updated 2 days ago."

check "code review creation" \
  "commit and CR this" \
  "execute_bash, execute_bash, execute_bash, execute_bash" \
  "Created CR-98765 with 3 files changed: hooks/cmux-notify.sh, hooks/cmux-summarize-notify.sh, tests/test-notifier.sh. Title: Fix notifier question detection rule."

check "explain code" \
  "how does the cookie refresh daemon work" \
  "fs_read, fs_read" \
  "The daemon in lib/cookie-refresh.sh polls ~/.midway/cookie mtime every 30s. When it changes, it re-runs the SSO curl flow for each tracked browser surface, re-injects cookies via the v2 socket, and reloads the page."

check "search results" \
  "find all TODO comments in the repo" \
  "execute_bash" \
  "Found 7 TODOs across 4 files: 3 in hooks/cmux-notify.sh (error handling), 2 in lib/auth.sh (timeout config), 1 in setup.sh (Linux support), 1 in bin/kiro-cmux (help text)."

check "dependency check" \
  "what version of jq do I have" \
  "execute_bash" \
  "jq 1.7.1 installed at /opt/homebrew/bin/jq."

check "multi-file refactor" \
  "rename all references of CMUX_TAB_ID to CMUX_WORKSPACE_ID" \
  "execute_bash, fs_read, fs_write, fs_write, fs_write, fs_write, fs_write" \
  "Renamed CMUX_TAB_ID to CMUX_WORKSPACE_ID in 5 files: cmux-notify.sh, cmux-title.sh, cmux-summarize-notify.sh, cmux-ssh, and setup.sh. 14 occurrences replaced total."

check "error with recovery" \
  "deploy the lambda" \
  "execute_bash, execute_bash, execute_bash, fs_write, execute_bash" \
  "Deploy failed initially — missing IAM permission lambda:UpdateFunctionCode. Added the permission to the role policy and redeployed successfully. Function my-notifier is now live at version 42."

check "wiki lookup" \
  "find the oncall runbook for builder-mcp" \
  "InternalSearch, ReadInternalWebsites" \
  "Found the runbook at w.amazon.com/bin/view/BuilderMCP/Oncall. Key sections: escalation contacts, common alarms (ACP timeout, MCP connection refused), and rollback steps."

check "empty response (no tools)" \
  "thanks" \
  "none" \
  "You're welcome! Let me know if you need anything else."

check "long multi-step task" \
  "set up the new microservice with DynamoDB, Lambda, and API Gateway" \
  "execute_bash, fs_write, fs_write, fs_write, fs_write, execute_bash, execute_bash, fs_write" \
  "Created the microservice scaffold: DynamoDB table (users-prod), Lambda function (user-handler) with Node.js 20 runtime, and API Gateway REST API with GET/POST /users endpoints. CDK stack deploys cleanly. Outputs: API URL https://abc123.execute-api.us-west-2.amazonaws.com/prod"

check "phonetool lookup" \
  "who is johndoe's manager" \
  "ReadInternalWebsites" \
  "johndoe (John Doe, SDE II, AWS Builder Tools) reports to janedoe (Jane Doe, SDM)."

check "debugging with action needed" \
  "the whoami didnt expand because he wrapped in single quotes" \
  "none" \
  "Ha — the \$(whoami) didnt expand because he wrapped the command in single quotes. The URL is literally phonetool.amazon.com/users/\$(whoami) which returns 404. Ask him to run: bash -x lib/auth-open.sh https://phonetool.amazon.com/users/sthyag 2>&1 | tee /tmp/auth-debug.log"

check "multi-file bug fix" \
  "their midway cookies were not stale though" \
  "fs_read, fs_write, fs_write" \
  "Two changes made to lib/auth.sh: 1. HTTP status check — curl -w http_code and bail if not 200. 2. httpOnly and expires fields — WKWebView was silently dropping session cookies without these fields, causing redirect to sentry."

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

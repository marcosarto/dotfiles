#!/bin/bash
# Tests for cmux hook injection logic in setup.sh
# Uses a temp directory with mock agent JSON files

PASS=0 FAIL=0
TMPDIR=$(mktemp -d)
INSTALL_DIR="/mock/cmux-kiro"
HOOK_CMD="$INSTALL_DIR/hooks/cmux-notify.sh"
FOREIGN_HOOK="/Users/test/.aim/packages/AIPowerUserCapabilities-1.0/agents/hooks/cmux-notify.sh"
EVENTS="agentSpawn userPromptSubmit preToolUse postToolUse stop"

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

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

# Mirrors setup.sh — "ours" means path contains cmux-kiro/
has_all_cmux_hooks() {
    local f="$1"
    local count=$(jq '[.hooks.agentSpawn, .hooks.userPromptSubmit, .hooks.preToolUse, .hooks.postToolUse, .hooks.stop | select(. != null) | map(select(.command | test("cmux-kiro/.*cmux-notify\\.sh"))) | select(length > 0)] | length' "$f" 2>/dev/null)
    [ "$count" -eq 5 ]
}

# Mirrors setup.sh injection logic — strips foreign, adds ours
inject_hooks() {
    local agents_dir="$1"
    local updated=0
    local eligible=""
    for agent_file in "$agents_dir"/*.json; do
        [ -f "$agent_file" ] || continue
        local bn=$(basename "$agent_file")
        echo "cmux.json cmux-titler.json cmux-notifier.json fast.json" | grep -qw "$bn" && continue
        jq empty "$agent_file" 2>/dev/null || continue
        has_all_cmux_hooks "$agent_file" && continue
        eligible="$eligible $bn"
    done
    [ -z "$eligible" ] && { echo "0"; return; }

    for agent_file in "$agents_dir"/*.json; do
        [ -f "$agent_file" ] || continue
        local bn=$(basename "$agent_file")
        echo "$eligible" | grep -qw "$bn" || continue

        local jq_filter='. | if .hooks == null then .hooks = {} else . end'
        for evt in $EVENTS; do
            # Strip foreign cmux-notify.sh
            jq_filter+=" | if .hooks.${evt} then .hooks.${evt} = [.hooks.${evt}[] | select((.command | test(\"cmux-notify\\\\.sh\")) and (.command | test(\"cmux-kiro/\") | not) | not)] else . end"
            # Add ours if missing
            jq_filter+=" | if (.hooks.${evt} // [] | map(select(.command | test(\"cmux-kiro/.*cmux-notify\\\\.sh\"))) | length) == 0"
            jq_filter+=" then .hooks.${evt} = (.hooks.${evt} // []) + [{\"command\": \"${HOOK_CMD}\", \"description\": \"cmux sidebar integration\"}]"
            jq_filter+=" else . end"
        done

        local result
        if result=$(jq "$jq_filter" "$agent_file" 2>/dev/null); then
            echo "$result" > "$agent_file"
            ((updated++)) || true
        fi
    done
    echo "$updated"
}

# Mirrors cmux-notify.sh runtime fix — only touches agents with foreign hooks
fix_foreign_hooks() {
    local agents_dir="$1"
    local our_hook="$HOOK_CMD"
    for f in "$agents_dir"/*.json; do
        [ -f "$f" ] || continue
        jq -e '[.hooks // {} | to_entries[] | .value[] | select(.command | test("cmux-notify\\.sh")) | select(.command | test("cmux-kiro/") | not)] | length > 0' "$f" >/dev/null 2>&1 || continue
        local jq_filter='.'
        for evt in $EVENTS; do
            jq_filter+=" | if .hooks.${evt} then .hooks.${evt} = [.hooks.${evt}[] | select((.command | test(\"cmux-notify\\\\.sh\")) and (.command | test(\"cmux-kiro/\") | not) | not)] else . end"
            jq_filter+=" | if (.hooks.${evt} // [] | map(select(.command | test(\"cmux-kiro/.*cmux-notify\\\\.sh\"))) | length) == 0"
            jq_filter+=" then .hooks.${evt} = (.hooks.${evt} // []) + [{\"command\": \"${our_hook}\", \"description\": \"cmux sidebar integration\"}]"
            jq_filter+=" else . end"
        done
        local result
        result=$(jq "$jq_filter" "$f" 2>/dev/null) && echo "$result" > "$f"
    done
}

# ── Basic injection ─────────────────────────────────────────

echo "=== Basic injection ==="

# --- Test 1: Fresh agent with no hooks ---
echo '{"name":"test-agent","tools":["*"]}' > "$TMPDIR/test1.json"
inject_hooks "$TMPDIR" >/dev/null
assert "Fresh agent gets all 5 hook events" \
    '[ "$(jq ".hooks | keys | length" "$TMPDIR/test1.json")" -eq 5 ]'
assert "Fresh agent hook command is correct" \
    '[ "$(jq -r ".hooks.agentSpawn[0].command" "$TMPDIR/test1.json")" = "$HOOK_CMD" ]'

# --- Test 2: Agent with existing hooks (no cmux) ---
cat > "$TMPDIR/test2.json" <<'EOF'
{"name":"builder","hooks":{"agentSpawn":[{"command":"aim agents publish-metrics || true"}]}}
EOF
inject_hooks "$TMPDIR" >/dev/null
assert "Existing hook preserved" \
    '[ "$(jq -r ".hooks.agentSpawn[0].command" "$TMPDIR/test2.json")" = "aim agents publish-metrics || true" ]'
assert "Cmux hook appended after existing" \
    '[ "$(jq -r ".hooks.agentSpawn[1].command" "$TMPDIR/test2.json")" = "$HOOK_CMD" ]'
assert "All 5 events present" \
    '[ "$(jq ".hooks | keys | length" "$TMPDIR/test2.json")" -eq 5 ]'

# --- Test 3: Idempotency — already has our hooks ---
cp "$TMPDIR/test1.json" "$TMPDIR/test3.json"
UPDATED=$(inject_hooks "$TMPDIR")
assert "No duplicate hooks after re-run" \
    '[ "$(jq ".hooks.agentSpawn | length" "$TMPDIR/test3.json")" -eq 1 ]'
assert "Zero agents updated on re-run" \
    '[ "$UPDATED" -eq 0 ]'

# --- Test 4: Partial cmux hooks (only agentSpawn) ---
cat > "$TMPDIR/test4.json" <<EOF
{"name":"partial","hooks":{"agentSpawn":[{"command":"$HOOK_CMD","description":"cmux sidebar integration"}]}}
EOF
inject_hooks "$TMPDIR" >/dev/null
assert "Existing cmux agentSpawn not duplicated" \
    '[ "$(jq ".hooks.agentSpawn | length" "$TMPDIR/test4.json")" -eq 1 ]'
assert "Missing events filled in" \
    '[ "$(jq -r ".hooks.stop[0].command" "$TMPDIR/test4.json")" = "$HOOK_CMD" ]'

# --- Test 5: cmux's own agents are skipped ---
echo '{"name":"cmux"}' > "$TMPDIR/cmux.json"
echo '{"name":"titler"}' > "$TMPDIR/cmux-titler.json"
echo '{"name":"notifier"}' > "$TMPDIR/cmux-notifier.json"
echo '{"name":"fast"}' > "$TMPDIR/fast.json"
inject_hooks "$TMPDIR" >/dev/null
assert "cmux.json not modified" \
    '[ "$(jq "has(\"hooks\")" "$TMPDIR/cmux.json")" = "false" ]'
assert "cmux-titler.json not modified" \
    '[ "$(jq "has(\"hooks\")" "$TMPDIR/cmux-titler.json")" = "false" ]'
assert "fast.json not modified" \
    '[ "$(jq "has(\"hooks\")" "$TMPDIR/fast.json")" = "false" ]'

# ── Foreign hook handling ───────────────────────────────────

echo ""
echo "=== Foreign hook handling (setup.sh) ==="

# --- Test 6: Foreign hooks replaced with ours ---
cat > "$TMPDIR/test6.json" <<EOF
{"name":"gpu-dev","hooks":{
  "agentSpawn":[{"command":"$FOREIGN_HOOK","timeout_ms":5000}],
  "userPromptSubmit":[{"command":"$FOREIGN_HOOK","timeout_ms":5000}],
  "preToolUse":[{"command":"$FOREIGN_HOOK","timeout_ms":5000}],
  "postToolUse":[{"command":"$FOREIGN_HOOK","timeout_ms":5000}],
  "stop":[{"command":"$FOREIGN_HOOK","timeout_ms":5000}]
}}
EOF
inject_hooks "$TMPDIR" >/dev/null
assert "Foreign agentSpawn replaced with ours" \
    '[ "$(jq -r ".hooks.agentSpawn[0].command" "$TMPDIR/test6.json")" = "$HOOK_CMD" ]'
assert "Foreign hook removed (only 1 entry per event)" \
    '[ "$(jq ".hooks.agentSpawn | length" "$TMPDIR/test6.json")" -eq 1 ]'
assert "All 5 events have our hook" \
    'has_all_cmux_hooks "$TMPDIR/test6.json"'

# --- Test 7: Foreign hooks replaced, other hooks preserved ---
cat > "$TMPDIR/test7.json" <<EOF
{"name":"gpu-dev-mixed","hooks":{
  "preToolUse":[
    {"command":"/some/guardrail","matcher":"use_aws"},
    {"command":"$FOREIGN_HOOK","timeout_ms":5000}
  ],
  "agentSpawn":[
    {"command":"aim agents publish-metrics || true"},
    {"command":"$FOREIGN_HOOK","timeout_ms":5000}
  ]
}}
EOF
inject_hooks "$TMPDIR" >/dev/null
assert "Guardrail hook preserved" \
    '[ "$(jq -r ".hooks.preToolUse[0].command" "$TMPDIR/test7.json")" = "/some/guardrail" ]'
assert "Metrics hook preserved" \
    '[ "$(jq -r ".hooks.agentSpawn[0].command" "$TMPDIR/test7.json")" = "aim agents publish-metrics || true" ]'
assert "Foreign hook removed from preToolUse" \
    '[ "$(jq "[.hooks.preToolUse[] | select(.command | test(\"AIPowerUser\"))] | length" "$TMPDIR/test7.json")" -eq 0 ]'
assert "Our hook added to preToolUse" \
    '[ "$(jq "[.hooks.preToolUse[] | select(.command | test(\"cmux-kiro/\"))] | length" "$TMPDIR/test7.json")" -eq 1 ]'

# --- Test 8: has_all_cmux_hooks rejects foreign-only ---
cat > "$TMPDIR/test8.json" <<EOF
{"name":"foreign-only","hooks":{
  "agentSpawn":[{"command":"$FOREIGN_HOOK"}],
  "userPromptSubmit":[{"command":"$FOREIGN_HOOK"}],
  "preToolUse":[{"command":"$FOREIGN_HOOK"}],
  "postToolUse":[{"command":"$FOREIGN_HOOK"}],
  "stop":[{"command":"$FOREIGN_HOOK"}]
}}
EOF
assert "has_all_cmux_hooks rejects foreign-only agent" \
    '! has_all_cmux_hooks "$TMPDIR/test8.json"'

# --- Test 9: has_all_cmux_hooks accepts ours ---
assert "has_all_cmux_hooks accepts agent with our hooks" \
    'has_all_cmux_hooks "$TMPDIR/test6.json"'

# --- Test 10: Idempotency after foreign replacement ---
inject_hooks "$TMPDIR" >/dev/null
assert "No duplicates after re-run on replaced agent" \
    '[ "$(jq ".hooks.agentSpawn | length" "$TMPDIR/test6.json")" -eq 1 ]'

# ── Runtime auto-fix (_fix_foreign_cmux_hooks) ─────────────

echo ""
echo "=== Runtime auto-fix ==="

# --- Test 11: Runtime fix replaces foreign hooks ---
RTDIR=$(mktemp -d)
cat > "$RTDIR/agent-a.json" <<EOF
{"name":"agent-a","hooks":{
  "agentSpawn":[{"command":"$FOREIGN_HOOK"}],
  "userPromptSubmit":[{"command":"$FOREIGN_HOOK"}],
  "preToolUse":[{"command":"$FOREIGN_HOOK"}],
  "postToolUse":[{"command":"$FOREIGN_HOOK"}],
  "stop":[{"command":"$FOREIGN_HOOK"}]
}}
EOF
fix_foreign_hooks "$RTDIR"
assert "Runtime fix replaces foreign hook" \
    '[ "$(jq -r ".hooks.agentSpawn[0].command" "$RTDIR/agent-a.json")" = "$HOOK_CMD" ]'
assert "Runtime fix adds all 5 events" \
    '[ "$(jq ".hooks | keys | length" "$RTDIR/agent-a.json")" -eq 5 ]'

# --- Test 12: Runtime fix skips agents with no cmux hooks ---
cat > "$RTDIR/agent-b.json" <<'EOF'
{"name":"agent-b","hooks":{"agentSpawn":[{"command":"some-other-hook"}]}}
EOF
fix_foreign_hooks "$RTDIR"
assert "Agent without cmux hooks untouched" \
    '[ "$(jq ".hooks | keys | length" "$RTDIR/agent-b.json")" -eq 1 ]'
assert "Non-cmux hook preserved" \
    '[ "$(jq -r ".hooks.agentSpawn[0].command" "$RTDIR/agent-b.json")" = "some-other-hook" ]'

# --- Test 13: Runtime fix skips agents already using ours ---
cat > "$RTDIR/agent-c.json" <<EOF
{"name":"agent-c","hooks":{
  "agentSpawn":[{"command":"$HOOK_CMD","description":"cmux sidebar integration"}],
  "userPromptSubmit":[{"command":"$HOOK_CMD"}],
  "preToolUse":[{"command":"$HOOK_CMD"}],
  "postToolUse":[{"command":"$HOOK_CMD"}],
  "stop":[{"command":"$HOOK_CMD"}]
}}
EOF
BEFORE=$(cat "$RTDIR/agent-c.json")
fix_foreign_hooks "$RTDIR"
AFTER=$(cat "$RTDIR/agent-c.json")
assert "Agent with our hooks not modified" \
    '[ "$BEFORE" = "$AFTER" ]'

# --- Test 14: Runtime fix preserves non-cmux hooks alongside replacement ---
cat > "$RTDIR/agent-d.json" <<EOF
{"name":"agent-d","hooks":{
  "preToolUse":[
    {"command":"/guardrail","matcher":"use_aws"},
    {"command":"$FOREIGN_HOOK"}
  ],
  "agentSpawn":[{"command":"$FOREIGN_HOOK"}]
}}
EOF
fix_foreign_hooks "$RTDIR"
assert "Runtime fix preserves guardrail" \
    '[ "$(jq -r ".hooks.preToolUse[0].command" "$RTDIR/agent-d.json")" = "/guardrail" ]'
assert "Runtime fix adds ours after guardrail" \
    '[ "$(jq -r ".hooks.preToolUse[1].command" "$RTDIR/agent-d.json")" = "$HOOK_CMD" ]'
assert "Runtime fix only has 2 preToolUse entries" \
    '[ "$(jq ".hooks.preToolUse | length" "$RTDIR/agent-d.json")" -eq 2 ]'

# --- Test 15: Runtime fix handles both foreign AND ours present ---
cat > "$RTDIR/agent-e.json" <<EOF
{"name":"agent-e","hooks":{
  "agentSpawn":[
    {"command":"$FOREIGN_HOOK"},
    {"command":"$HOOK_CMD","description":"cmux sidebar integration"}
  ]
}}
EOF
fix_foreign_hooks "$RTDIR"
assert "Foreign removed when both present" \
    '[ "$(jq "[.hooks.agentSpawn[] | select(.command | test(\"AIPowerUser\"))] | length" "$RTDIR/agent-e.json")" -eq 0 ]'
assert "Ours kept when both present" \
    '[ "$(jq "[.hooks.agentSpawn[] | select(.command | test(\"cmux-kiro/\"))] | length" "$RTDIR/agent-e.json")" -eq 1 ]'

# --- Test 16: Simulated aim reinstall → runtime fix cycle ---
cat > "$RTDIR/agent-f.json" <<EOF
{"name":"agent-f","hooks":{
  "agentSpawn":[{"command":"$HOOK_CMD","description":"cmux sidebar integration"}],
  "userPromptSubmit":[{"command":"$HOOK_CMD"}],
  "preToolUse":[{"command":"/guardrail"},{"command":"$HOOK_CMD"}],
  "postToolUse":[{"command":"$HOOK_CMD"}],
  "stop":[{"command":"$HOOK_CMD"}]
}}
EOF
# Simulate aim agents install clobbering our hooks with foreign ones
cat > "$RTDIR/agent-f.json" <<EOF
{"name":"agent-f","hooks":{
  "agentSpawn":[{"command":"$FOREIGN_HOOK","timeout_ms":5000}],
  "userPromptSubmit":[{"command":"$FOREIGN_HOOK","timeout_ms":5000}],
  "preToolUse":[{"command":"/guardrail"},{"command":"$FOREIGN_HOOK","timeout_ms":5000}],
  "postToolUse":[{"command":"$FOREIGN_HOOK","timeout_ms":5000}],
  "stop":[{"command":"$FOREIGN_HOOK","timeout_ms":5000}]
}}
EOF
fix_foreign_hooks "$RTDIR"
assert "After aim reinstall: foreign replaced with ours" \
    '[ "$(jq -r ".hooks.agentSpawn[0].command" "$RTDIR/agent-f.json")" = "$HOOK_CMD" ]'
assert "After aim reinstall: guardrail preserved" \
    '[ "$(jq -r ".hooks.preToolUse[0].command" "$RTDIR/agent-f.json")" = "/guardrail" ]'
assert "After aim reinstall: all events have our hook" \
    '[ "$(jq "[.hooks | to_entries[] | .value[] | select(.command | test(\"cmux-kiro/\"))] | length" "$RTDIR/agent-f.json")" -eq 5 ]'
assert "After aim reinstall: no foreign hooks remain" \
    '[ "$(jq "[.hooks | to_entries[] | .value[] | select(.command | test(\"AIPowerUser\"))] | length" "$RTDIR/agent-f.json")" -eq 0 ]'

rm -rf "$RTDIR"

# ── Hook removal ────────────────────────────────────────────

echo ""
echo "=== Hook removal ==="

# --- Test 17: Removal strips our hooks, preserves others ---
cat > "$TMPDIR/test17.json" <<EOF
{"name":"removable","hooks":{"agentSpawn":[{"command":"aim metrics || true"},{"command":"$HOOK_CMD","description":"cmux sidebar integration"}],"stop":[{"command":"$HOOK_CMD","description":"cmux sidebar integration"}]}}
EOF
EVENTS_LIST="agentSpawn userPromptSubmit preToolUse postToolUse stop"
jq_filter='.'
for evt in $EVENTS_LIST; do
    jq_filter+=" | if .hooks.${evt} then .hooks.${evt} = [.hooks.${evt}[] | select(.command | contains(\"cmux-notify.sh\") | not)] else . end"
    jq_filter+=" | if .hooks.${evt} == [] then del(.hooks.${evt}) else . end"
done
jq_filter+=' | if .hooks == {} then del(.hooks) else . end'
result=$(jq "$jq_filter" "$TMPDIR/test17.json") && echo "$result" > "$TMPDIR/test17.json"
assert "Removal preserves non-cmux hooks" \
    '[ "$(jq -r ".hooks.agentSpawn[0].command" "$TMPDIR/test17.json")" = "aim metrics || true" ]'
assert "Removal deletes cmux hook entries" \
    '[ "$(jq ".hooks.agentSpawn | length" "$TMPDIR/test17.json")" -eq 1 ]'
assert "Removal cleans up empty event arrays" \
    '[ "$(jq ".hooks | has(\"stop\")" "$TMPDIR/test17.json")" = "false" ]'

# --- Test 18: Removal also strips foreign cmux-notify.sh ---
cat > "$TMPDIR/test18.json" <<EOF
{"name":"mixed-removal","hooks":{"agentSpawn":[{"command":"$FOREIGN_HOOK"},{"command":"$HOOK_CMD"}]}}
EOF
jq_filter='.'
for evt in $EVENTS_LIST; do
    jq_filter+=" | if .hooks.${evt} then .hooks.${evt} = [.hooks.${evt}[] | select(.command | contains(\"cmux-notify.sh\") | not)] else . end"
    jq_filter+=" | if .hooks.${evt} == [] then del(.hooks.${evt}) else . end"
done
jq_filter+=' | if .hooks == {} then del(.hooks) else . end'
result=$(jq "$jq_filter" "$TMPDIR/test18.json") && echo "$result" > "$TMPDIR/test18.json"
assert "Removal strips both foreign and ours" \
    '[ "$(jq "has(\"hooks\")" "$TMPDIR/test18.json")" = "false" ]'

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1

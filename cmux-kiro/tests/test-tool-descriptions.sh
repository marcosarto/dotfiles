#!/bin/bash
# Tests for _tool_description, _tool_icon, and fallback humanization

PASS=0 FAIL=0
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/hooks/cmux-notify.sh"

# Extract functions from cmux-notify.sh without running the hook logic.
# Source everything between the first function definition and the first
# non-function line after the last function (STATE_DIR / KIRO_TITLE_ICON).
eval "$(sed -n '/^_describe_command()/,/^KIRO_TITLE_ICON=/{ /^KIRO_TITLE_ICON=/d; p; }' "$SCRIPT")"

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

# ── _tool_icon ──────────────────────────────────────────────

echo "=== _tool_icon ==="

# Native tools
assert "fs_read icon"       "doc.text"              "$(_tool_icon fs_read)"
assert "read icon"          "doc.text"              "$(_tool_icon read)"
assert "fs_write icon"      "pencil"                "$(_tool_icon fs_write)"
assert "write icon"         "pencil"                "$(_tool_icon write)"
assert "execute_bash icon"  "terminal"              "$(_tool_icon execute_bash)"
assert "shell icon"         "terminal"              "$(_tool_icon shell)"
assert "use_aws icon"       "cloud"                 "$(_tool_icon use_aws)"
assert "aws icon"           "cloud"                 "$(_tool_icon aws)"
assert "use_subagent icon"  "arrow.triangle.branch" "$(_tool_icon use_subagent)"
assert "subagent icon"      "arrow.triangle.branch" "$(_tool_icon subagent)"
assert "web_search icon"    "magnifyingglass"       "$(_tool_icon web_search)"
assert "web_fetch icon"     "globe"                 "$(_tool_icon web_fetch)"
assert "code icon"          "magnifyingglass"       "$(_tool_icon code)"
assert "grep icon"          "magnifyingglass"       "$(_tool_icon grep)"
assert "glob icon"          "doc.text"              "$(_tool_icon glob)"
assert "thinking icon"      "brain"                 "$(_tool_icon thinking)"
assert "todo_list icon"     "checklist"             "$(_tool_icon todo_list)"
assert "knowledge icon"     "book"                  "$(_tool_icon knowledge)"
assert "introspect icon"    "info.circle"           "$(_tool_icon introspect)"
assert "report_issue icon"  "info.circle"           "$(_tool_icon report_issue)"

# MCP tools (glob patterns)
assert "InternalSearch icon"     "magnifyingglass"       "$(_tool_icon '@builder-mcp/InternalSearch')"
assert "InternalCodeSearch icon" "magnifyingglass"       "$(_tool_icon '@builder-mcp/InternalCodeSearch')"
assert "ReadInternalWebsites"    "globe"                 "$(_tool_icon '@builder-mcp/ReadInternalWebsites')"
assert "WorkspaceSearch icon"    "magnifyingglass"       "$(_tool_icon '@builder-mcp/WorkspaceSearch')"
assert "QuipEditor icon"         "doc.on.doc"            "$(_tool_icon '@builder-mcp/QuipEditor')"
assert "CRRevisionCreator icon"  "arrow.triangle.pull"   "$(_tool_icon '@builder-mcp/CRRevisionCreator')"
assert "BrazilBuildAnalyzer"     "hammer"                "$(_tool_icon '@builder-mcp/BrazilBuildAnalyzer')"
assert "BrazilWorkspace icon"    "hammer"                "$(_tool_icon '@builder-mcp/BrazilWorkspace')"
assert "GetPipelineDetails"      "arrow.triangle.capsulepath" "$(_tool_icon '@builder-mcp/GetPipelineDetails')"
assert "TaskeiGetTask icon"      "tag"                   "$(_tool_icon '@builder-mcp/TaskeiGetTask')"
assert "TicketingReadActions"    "tag"                   "$(_tool_icon '@builder-mcp/TicketingReadActions')"
assert "ReadRemoteTestRun icon"  "testtube.2"            "$(_tool_icon '@builder-mcp/ReadRemoteTestRun')"
assert "SkillsTool icon"         "sparkles"              "$(_tool_icon '@builder-mcp/SkillsTool')"
assert "github icon"             "arrow.triangle.pull"   "$(_tool_icon '@github/search_pull_requests')"
assert "pippin icon"             "chart.bar"             "$(_tool_icon '@pippin-mcp/pippin_get_artifact')"
assert "slack icon"              "bubble.left.and.bubble.right" "$(_tool_icon '@ai-community-slack-mcp/post')"
assert "outlook icon"            "envelope"              "$(_tool_icon '@aws-outlook-mcp/read_mail')"
assert "coe icon"                "exclamationmark.triangle" "$(_tool_icon '@coe-mcp/get_coe')"
assert "lusca icon"              "magnifyingglass"       "$(_tool_icon '@lusca-search-mcp/search')"

# Fallback
assert "unknown icon"       "bolt.fill"             "$(_tool_icon 'totally_unknown')"

# ── _tool_description (present tense) ──────────────────────

echo ""
echo "=== _tool_description (present) ==="

# With TOOL_INPUT context
TOOL_INPUT='{"operations":[{"path":"/foo/bar/config.ts","mode":"Line"}]}'
assert "fs_read with path"  "Reading config.ts"     "$(_tool_description fs_read)"
assert "read with path"     "Reading config.ts"     "$(_tool_description read)"

TOOL_INPUT='{"operations":[{"path":".","mode":"Directory"}]}'
assert "read dir ."         "Listing directory"     "$(_tool_description read)"

TOOL_INPUT='{"operations":[{"path":"/foo/bar/src","mode":"Directory"}]}'
assert "read dir named"     "Listing src"           "$(_tool_description read)"

TOOL_INPUT='{"operations":[{"mode":"Image","image_paths":["/tmp/img.png"]}]}'
assert "read image"         "Viewing image"         "$(_tool_description read)"

TOOL_INPUT='{"path":"/foo/bar/index.js"}'
assert "fs_write with path" "Writing index.js"      "$(_tool_description fs_write)"
assert "write with path"    "Writing index.js"      "$(_tool_description write)"

TOOL_INPUT='{"operation":"search_symbols","symbol_name":"auth handler"}'
assert "code with symbol"   "Finding auth handler"  "$(_tool_description code)"

TOOL_INPUT='{"operation":"goto_definition"}'
assert "code goto def"      "Finding definition"    "$(_tool_description code)"

TOOL_INPUT='{"operation":"get_diagnostics"}'
assert "code diagnostics"   "Checking diagnostics"  "$(_tool_description code)"

TOOL_INPUT='{"operation":"generate_codebase_overview"}'
assert "code overview"      "Mapping codebase"      "$(_tool_description code)"

TOOL_INPUT='{"pattern":"TODO"}'
assert "grep with pattern"  "Grepping: TODO"        "$(_tool_description grep)"

TOOL_INPUT='{"pattern":"**/*.ts"}'
assert "glob with pattern"  "Finding files: **/*.ts" "$(_tool_description glob)"

TOOL_INPUT='{}'
assert "thinking"           "Thinking"              "$(_tool_description thinking)"
assert "todo_list"          "Updating tasks"        "$(_tool_description todo_list)"
assert "knowledge"          "Looking up docs"       "$(_tool_description knowledge)"
assert "introspect"         "Introspecting"         "$(_tool_description introspect)"
assert "use_subagent"       "Delegating to subagent" "$(_tool_description use_subagent)"
assert "subagent"           "Delegating to subagent" "$(_tool_description subagent)"

# MCP tools
assert "CRRevisionCreator"  "Creating CR"           "$(_tool_description '@builder-mcp/CRRevisionCreator')"
assert "TaskeiCreateTask"   "Created task"          "$(_tool_description '@builder-mcp/TaskeiCreateTask' past)"
assert "SkillsTool"         "Using skill"           "$(_tool_description '@builder-mcp/SkillsTool')"

# ── _tool_description (past tense) ─────────────────────────

echo ""
echo "=== _tool_description (past) ==="

TOOL_INPUT='{"operations":[{"path":"/foo/bar/config.ts","mode":"Line"}]}'
assert "fs_read past"       "Read config.ts"        "$(_tool_description fs_read past)"
assert "read past"          "Read config.ts"        "$(_tool_description read past)"

TOOL_INPUT='{"operations":[{"path":".","mode":"Directory"}]}'
assert "read dir . past"    "Listed directory"      "$(_tool_description read past)"

TOOL_INPUT='{"path":"/foo/bar/index.js"}'
assert "fs_write past"      "Wrote index.js"        "$(_tool_description fs_write past)"

TOOL_INPUT='{"operation":"search_symbols","symbol_name":"auth handler"}'
assert "code past"          "Found auth handler"    "$(_tool_description code past)"

TOOL_INPUT='{"pattern":"TODO"}'
assert "grep past"          "Grepped: TODO"         "$(_tool_description grep past)"

TOOL_INPUT='{"pattern":"**/*.ts"}'
assert "glob past"          "Found files: **/*.ts"  "$(_tool_description glob past)"

TOOL_INPUT='{}'
assert "thinking past"      "Thought"               "$(_tool_description thinking past)"
assert "todo_list past"     "Updated tasks"         "$(_tool_description todo_list past)"
assert "use_subagent past"  "Delegated to subagent" "$(_tool_description use_subagent past)"

# ── Fallback humanization ──────────────────────────────────

echo ""
echo "=== Fallback (unknown tools) ==="

TOOL_INPUT='{}'
assert "MCP fallback present"  "Using @builder-mcp"       "$(_tool_description '@builder-mcp/SomeFutureTool')"
assert "MCP fallback past"     "Used @builder-mcp"        "$(_tool_description '@builder-mcp/SomeFutureTool' past)"
assert "MCP fallback pippin"   "Querying Pippin"          "$(_tool_description '@pippin-mcp/some_new_thing')"
assert "Native fallback present" "Using Some Unknown Tool" "$(_tool_description 'some_unknown_tool')"
assert "Native fallback past"  "Used Some Unknown Tool"   "$(_tool_description 'some_unknown_tool' past)"
assert "CamelCase fallback"    "Using My Fancy Tool"      "$(_tool_description 'MyFancyTool')"

# ── Summary ─────────────────────────────────────────────────

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1

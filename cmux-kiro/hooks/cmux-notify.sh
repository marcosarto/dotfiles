#!/bin/bash
# If configured socket is gone, try known fallback paths (e.g. cmux moved it after an update)
if [ -n "$CMUX_SOCKET_PATH" ] && [ ! -S "$CMUX_SOCKET_PATH" ]; then
    for _sock in "/tmp/cmux.sock" "$HOME/Library/Application Support/cmux/cmux.sock"; do
        if [ -S "$_sock" ]; then
            export CMUX_SOCKET_PATH="$_sock"
            break
        fi
    done
fi
[ -n "$CMUX_SOCKET_PATH" ] && [ -S "$CMUX_SOCKET_PATH" ] || exit 0
[ -n "$CMUX_TAB_ID" ] || exit 0
[ -n "$CMUX_PANEL_ID" ] || exit 0

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_DIR/lib/auth.sh"

WS="$CMUX_WORKSPACE_ID"
EVENT=$(cat 2>/dev/null || echo '{}')
EVENT_NAME=$(echo "$EVENT" | jq -r '.hook_event_name // "unknown"' 2>/dev/null)
TOOL=$(echo "$EVENT" | jq -r '.tool_name // ""' 2>/dev/null)
CWD=$(echo "$EVENT" | jq -r '.cwd // ""' 2>/dev/null)
PROMPT=$(echo "$EVENT" | jq -r '.prompt // ""' 2>/dev/null)
TOOL_INPUT=$(echo "$EVENT" | jq -r '.tool_input // empty' 2>/dev/null)

_describe_command() {
    local cmd="$1" past="$2"
    [ -z "$cmd" ] && { [ "$past" = "past" ] && echo "Ran command" || echo "Running command"; return; }
    local clean=$(echo "$cmd" | sed 's/^[A-Z_]*=[^ ]* *//g; s/^cd [^;&|]* *[;&|]* *//; s/^sudo //')
    local bin=$(echo "$clean" | awk '{print $1}' | sed 's|.*/||')
    case "$bin" in
        grep|rg|ag)
            local pattern=$(echo "$clean" | sed -n 's/.*grep[[:space:]]*\(-[^ ]*[[:space:]]*\)*\([^ ]*\).*/\2/p' | head -c 20)
            [ "$past" = "past" ] && echo "Searched for ${pattern:-pattern}" || echo "Searching for ${pattern:-pattern}" ;;
        git)
            local sub=$(echo "$clean" | awk '{print $2}')
            case "$sub" in
                status|diff|log|show|branch) [ "$past" = "past" ] && echo "Checked git $sub" || echo "Checking git $sub" ;;
                pull|fetch|push|rebase|merge) [ "$past" = "past" ] && echo "Ran git $sub" || echo "Running git $sub" ;;
                add|commit) [ "$past" = "past" ] && echo "Committed changes" || echo "Committing changes" ;;
                *) [ "$past" = "past" ] && echo "Ran git $sub" || echo "Running git $sub" ;;
            esac ;;
        cat|head|tail|less|more)
            local file=$(echo "$clean" | awk '{print $NF}' | sed 's|.*/||' | head -c 20)
            [ "$past" = "past" ] && echo "Read $file" || echo "Reading $file" ;;
        ls|find|tree) [ "$past" = "past" ] && echo "Listed directory" || echo "Listing directory" ;;
        npm|yarn|pnpm)
            local sub=$(echo "$clean" | awk '{print $2}')
            case "$sub" in
                test) [ "$past" = "past" ] && echo "Ran tests" || echo "Running tests" ;;
                install|i) [ "$past" = "past" ] && echo "Installed packages" || echo "Installing packages" ;;
                build) [ "$past" = "past" ] && echo "Built project" || echo "Building project" ;;
                *) [ "$past" = "past" ] && echo "Ran $bin $sub" || echo "Running $bin $sub" ;;
            esac ;;
        pytest|jest|mocha|cargo)
            local sub=$(echo "$clean" | awk '{print $2}')
            if [ "$bin" = "cargo" ] && [ "$sub" = "test" ]; then
                [ "$past" = "past" ] && echo "Ran tests" || echo "Running tests"
            elif [ "$bin" = "cargo" ]; then
                [ "$past" = "past" ] && echo "Ran cargo $sub" || echo "Running cargo $sub"
            else
                [ "$past" = "past" ] && echo "Ran tests" || echo "Running tests"
            fi ;;
        make|cmake|brazil) [ "$past" = "past" ] && echo "Built project" || echo "Building project" ;;
        curl|wget) [ "$past" = "past" ] && echo "Fetched URL" || echo "Fetching URL" ;;
        chmod|chown|mkdir|mv|cp|rm|ln) [ "$past" = "past" ] && echo "Modified filesystem" || echo "Modifying filesystem" ;;
        sed|awk|tr|sort|cut|wc) [ "$past" = "past" ] && echo "Processed text" || echo "Processing text" ;;
        echo|printf)
            if echo "$clean" | grep -q '| *nc\b'; then
                [ "$past" = "past" ] && echo "Sent socket command" || echo "Sending socket command"
            elif echo "$clean" | grep -q '>'; then
                [ "$past" = "past" ] && echo "Wrote to file" || echo "Writing to file"
            else
                [ "$past" = "past" ] && echo "Ran command" || echo "Running command"
            fi ;;
        cr) [ "$past" = "past" ] && echo "Created code review" || echo "Creating code review" ;;
        ssh|scp|rsync) [ "$past" = "past" ] && echo "Ran remote command" || echo "Running remote command" ;;
        docker|podman) [ "$past" = "past" ] && echo "Ran container command" || echo "Running container command" ;;
        python*|node|ruby|perl|bash|sh|zsh)
            local script=$(echo "$clean" | awk '{skip=0; for(i=2;i<=NF;i++){if(skip){skip=0;continue} if($i ~ /^<</){skip=1;continue} if($i !~ /^-/){print $i;exit}}}' | sed 's|.*/||' | head -c 20)
            [ "$past" = "past" ] && echo "Ran ${script:-script}" || echo "Running ${script:-script}" ;;
        *) [ "$past" = "past" ] && echo "Ran shell command" || echo "Running shell command" ;;
    esac
}

# Returns (description, icon) — icon is tool-contextual for in-progress, checkmark for completed
_tool_icon() {
    local name="$1"
    case "$name" in
        fs_read|read) echo "doc.text" ;;
        fs_write|write) echo "pencil" ;;
        execute_bash|shell) echo "terminal" ;;
        InternalSearch|*InternalSearch) echo "magnifyingglass" ;;
        ReadInternalWebsites|*ReadInternalWebsites) echo "globe" ;;
        web_search) echo "magnifyingglass" ;;
        web_fetch) echo "globe" ;;
        use_aws|aws) echo "cloud" ;;
        QuipEditor|*QuipEditor) echo "doc.on.doc" ;;
        code) echo "magnifyingglass" ;;
        grep) echo "magnifyingglass" ;;
        glob) echo "doc.text" ;;
        use_subagent|subagent) echo "arrow.triangle.branch" ;;
        thinking) echo "brain" ;;
        todo_list|task) echo "checklist" ;;
        knowledge|*aws_*) echo "book" ;;
        introspect|report_issue) echo "info.circle" ;;
        *InternalCodeSearch) echo "magnifyingglass" ;;
        *WorkspaceSearch) echo "magnifyingglass" ;;
        *CRRevisionCreator) echo "arrow.triangle.pull" ;;
        *BrazilBuild*|*BrazilPackage*|*BrazilWorkspace) echo "hammer" ;;
        *GetPipeline*) echo "arrow.triangle.capsulepath" ;;
        *Taskei*|*TicketingReadActions) echo "tag" ;;
        *ReadRemoteTestRun) echo "testtube.2" ;;
        *SkillsTool) echo "sparkles" ;;
        *github*) echo "arrow.triangle.pull" ;;
        *pippin*) echo "chart.bar" ;;
        *slack*) echo "bubble.left.and.bubble.right" ;;
        *outlook*) echo "envelope" ;;
        *coe*) echo "exclamationmark.triangle" ;;
        *lusca*) echo "magnifyingglass" ;;
        *) echo "bolt.fill" ;;
    esac
}

_tool_description() {
    local name="$1" past="$2"
    case "$name" in
        fs_read|read)
            local mode=$(echo "$TOOL_INPUT" | jq -r '.operations[0].mode // empty' 2>/dev/null)
            local p=$(echo "$TOOL_INPUT" | jq -r '.operations[0].path // empty' 2>/dev/null)
            local label="${p##*/}"
            # Resolve unhelpful path names
            [[ "$label" == "." || "$label" == ".." || -z "$label" ]] && label=""
            case "$mode" in
                Directory) [ "$past" = "past" ] && echo "Listed ${label:-directory}" || echo "Listing ${label:-directory}" ;;
                Image) [ "$past" = "past" ] && echo "Viewed image" || echo "Viewing image" ;;
                *) [ "$past" = "past" ] && { [ -n "$label" ] && echo "Read $label" || echo "Read files"; } \
                                         || { [ -n "$label" ] && echo "Reading $label" || echo "Reading files"; } ;;
            esac ;;
        fs_write|write)
            local p=$(echo "$TOOL_INPUT" | jq -r '.path // empty' 2>/dev/null)
            [ "$past" = "past" ] && { [ -n "$p" ] && echo "Wrote ${p##*/}" || echo "Wrote file"; } \
                                 || { [ -n "$p" ] && echo "Writing ${p##*/}" || echo "Writing file"; } ;;
        execute_bash|shell)
            echo "$(_describe_command "$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)" "$past")" ;;
        InternalSearch|*InternalSearch)
            local q=$(echo "$TOOL_INPUT" | jq -r '.query // empty' 2>/dev/null | head -c 30)
            [ "$past" = "past" ] && { [ -n "$q" ] && echo "Searched: $q" || echo "Searched"; } \
                                 || { [ -n "$q" ] && echo "Searching: $q" || echo "Searching"; } ;;
        ReadInternalWebsites|*ReadInternalWebsites)
            local url=$(echo "$TOOL_INPUT" | jq -r '.inputs[0] // empty' 2>/dev/null | sed 's|https://||' | head -c 30)
            [ "$past" = "past" ] && { [ -n "$url" ] && echo "Fetched $url" || echo "Fetched page"; } \
                                 || { [ -n "$url" ] && echo "Fetching $url" || echo "Fetching page"; } ;;
        web_search)
            local q=$(echo "$TOOL_INPUT" | jq -r '.query // empty' 2>/dev/null | head -c 30)
            [ "$past" = "past" ] && { [ -n "$q" ] && echo "Searched: $q" || echo "Web searched"; } \
                                 || { [ -n "$q" ] && echo "Searching: $q" || echo "Web search"; } ;;
        use_aws|aws)
            local svc=$(echo "$TOOL_INPUT" | jq -r '.service_name // empty' 2>/dev/null)
            local op=$(echo "$TOOL_INPUT" | jq -r '.operation_name // empty' 2>/dev/null)
            [ -n "$svc" ] && echo "AWS: $svc $op" || echo "AWS call" ;;
        QuipEditor|*QuipEditor)
            local doc=$(echo "$TOOL_INPUT" | jq -r '.documentId // empty' 2>/dev/null)
            [ -n "$doc" ] && echo "Quip: $doc" || echo "Quip doc" ;;
        web_fetch)
            local url=$(echo "$TOOL_INPUT" | jq -r '.url // empty' 2>/dev/null | sed 's|https://||' | head -c 30)
            [ "$past" = "past" ] && { [ -n "$url" ] && echo "Fetched $url" || echo "Fetched URL"; } \
                                 || { [ -n "$url" ] && echo "Fetching $url" || echo "Fetching URL"; } ;;
        use_subagent|subagent) [ "$past" = "past" ] && echo "Delegated to subagent" || echo "Delegating to subagent" ;;
        code)
            local op=$(echo "$TOOL_INPUT" | jq -r '.operation // empty' 2>/dev/null)
            local sym=$(echo "$TOOL_INPUT" | jq -r '.symbol_name // .pattern // empty' 2>/dev/null | head -c 25)
            case "$op" in
                search_symbols|lookup_symbols) [ "$past" = "past" ] && echo "Found ${sym:-symbols}" || echo "Finding ${sym:-symbols}" ;;
                find_references) [ "$past" = "past" ] && echo "Found refs: ${sym:-symbol}" || echo "Finding refs: ${sym:-symbol}" ;;
                goto_definition) [ "$past" = "past" ] && echo "Found definition" || echo "Finding definition" ;;
                get_diagnostics) [ "$past" = "past" ] && echo "Checked diagnostics" || echo "Checking diagnostics" ;;
                rename_symbol) [ "$past" = "past" ] && echo "Renamed ${sym:-symbol}" || echo "Renaming ${sym:-symbol}" ;;
                pattern_search|pattern_rewrite) [ "$past" = "past" ] && echo "AST search" || echo "AST searching" ;;
                generate_codebase_overview|search_codebase_map) [ "$past" = "past" ] && echo "Mapped codebase" || echo "Mapping codebase" ;;
                *) [ "$past" = "past" ] && echo "Analyzed code" || echo "Analyzing code" ;;
            esac ;;
        grep)
            local q=$(echo "$TOOL_INPUT" | jq -r '.pattern // .query // empty' 2>/dev/null | head -c 30)
            [ "$past" = "past" ] && { [ -n "$q" ] && echo "Grepped: $q" || echo "Grepped"; } \
                                 || { [ -n "$q" ] && echo "Grepping: $q" || echo "Grepping"; } ;;
        glob)
            local q=$(echo "$TOOL_INPUT" | jq -r '.pattern // empty' 2>/dev/null | head -c 30)
            [ "$past" = "past" ] && { [ -n "$q" ] && echo "Found files: $q" || echo "Found files"; } \
                                 || { [ -n "$q" ] && echo "Finding files: $q" || echo "Finding files"; } ;;
        thinking) [ "$past" = "past" ] && echo "Thought" || echo "Thinking" ;;
        todo_list|task) [ "$past" = "past" ] && echo "Updated tasks" || echo "Updating tasks" ;;
        knowledge|*aws_*) [ "$past" = "past" ] && echo "Looked up docs" || echo "Looking up docs" ;;
        introspect) [ "$past" = "past" ] && echo "Introspected" || echo "Introspecting" ;;
        report_issue) [ "$past" = "past" ] && echo "Reported issue" || echo "Reporting issue" ;;
        *InternalCodeSearch)
            local q=$(echo "$TOOL_INPUT" | jq -r '.query // empty' 2>/dev/null | head -c 30)
            [ "$past" = "past" ] && { [ -n "$q" ] && echo "Searched code: $q" || echo "Searched code"; } \
                                 || { [ -n "$q" ] && echo "Searching code: $q" || echo "Searching code"; } ;;
        *WorkspaceSearch)
            local q=$(echo "$TOOL_INPUT" | jq -r '.searchQuery // .query // empty' 2>/dev/null | head -c 30)
            [ "$past" = "past" ] && { [ -n "$q" ] && echo "Searched workspace: $q" || echo "Searched workspace"; } \
                                 || { [ -n "$q" ] && echo "Searching workspace: $q" || echo "Searching workspace"; } ;;
        *CRRevisionCreator) [ "$past" = "past" ] && echo "Created CR" || echo "Creating CR" ;;
        *BrazilBuild*|*BrazilPackage*) [ "$past" = "past" ] && echo "Analyzed build" || echo "Analyzing build" ;;
        *BrazilWorkspace) [ "$past" = "past" ] && echo "Checked workspace" || echo "Checking workspace" ;;
        *GetPipeline*) [ "$past" = "past" ] && echo "Checked pipeline" || echo "Checking pipeline" ;;
        *TaskeiCreateTask) [ "$past" = "past" ] && echo "Created task" || echo "Creating task" ;;
        *TaskeiUpdateTask) [ "$past" = "past" ] && echo "Updated task" || echo "Updating task" ;;
        *TaskeiGetTask|*TaskeiListTasks|*TaskeiGetRoom*) [ "$past" = "past" ] && echo "Fetched tasks" || echo "Fetching tasks" ;;
        *TicketingReadActions) [ "$past" = "past" ] && echo "Read ticket" || echo "Reading ticket" ;;
        *ReadRemoteTestRun) [ "$past" = "past" ] && echo "Read test run" || echo "Reading test run" ;;
        *SkillsTool) [ "$past" = "past" ] && echo "Used skill" || echo "Using skill" ;;
        *github*) echo "GitHub" ;;
        *pippin*) [ "$past" = "past" ] && echo "Queried Pippin" || echo "Querying Pippin" ;;
        *slack*) [ "$past" = "past" ] && echo "Checked Slack" || echo "Checking Slack" ;;
        *outlook*) [ "$past" = "past" ] && echo "Checked email" || echo "Checking email" ;;
        *coe*) [ "$past" = "past" ] && echo "Checked COE" || echo "Checking COE" ;;
        *lusca*) [ "$past" = "past" ] && echo "Searched Lusca" || echo "Searching Lusca" ;;
        *) local prefix; [ "$past" = "past" ] && prefix="Used" || prefix="Using"
            if [[ "$name" == @*/* ]]; then
                echo "$prefix ${name%%/*}"
            else
                echo "$prefix $name" | sed 's/_/ /g; s/\([a-z]\)\([A-Z]\)/\1 \2/g' | awk '{for(i=1;i<=NF;i++) if(i>1) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}' | head -c 40
            fi ;;
    esac
}

KIRO_TITLE_ICON="◆"
# State-based sidebar colors
COLOR_THINKING="#ff9500"   # orange — agent is generating
COLOR_TOOL="#5ac8fa"       # blue — running a tool
COLOR_WAITING="#bf5af2"    # purple — needs user input
COLOR_IDLE="#30d158"       # green — turn complete
COLOR_ERROR="#ff453a"      # red — tool failure
STATE_DIR="/tmp/kiro-cmux-$WS"
mkdir -p "$STATE_DIR" 2>/dev/null
SESSION_TOKEN=$(cat "$STATE_DIR/session_pid" 2>/dev/null)

# Set workspace accent color (requires cmux 0.63+ / nightly). Silently no-ops on older versions.
_set_workspace_color() {
    cmux workspace-action --workspace "$WS" --action set-color --color "$1" >/dev/null 2>&1 || true
}

# Extract tool response text from event JSON. Handles both:
#   Old CLI: .tool_response.result (string)
#   New TUI: .tool_response.items[] with .Json or .Text
_tool_response_text() {
    echo "$1" | jq -r '
        (.tool_response.result // empty),
        (.tool_response.items // [] | map(
            if .Text then .Text
            elif .Json then (.Json | tostring)
            else empty end
        ) | join("\n"))
    ' 2>/dev/null
}

_report_git() {
    local dir="${1:-$PWD}"
    [ -d "$dir" ] || return 0
    local branch
    branch=$(git -C "$dir" branch --show-current 2>/dev/null)
    if [ -n "$branch" ]; then
        local first dirty_opt=""
        first=$(git -C "$dir" status --porcelain -uno 2>/dev/null | head -1)
        [ -n "$first" ] && dirty_opt="--status=dirty"
        echo "report_git_branch $branch $dirty_opt --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID" | nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1
    else
        echo "clear_git_branch --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID" | nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1
    fi
    echo "report_pwd $(basename "$dir") --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID" | nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1
}

_workspace_label() {
    basename "${1:-$PWD}" 2>/dev/null || echo "Kiro"
}

# Replace foreign cmux-notify.sh hooks (e.g. AIPowerUserCapabilities) with ours in opted-in agent JSONs
_fix_foreign_cmux_hooks() {
    local our_hook="$REPO_DIR/hooks/cmux-notify.sh"
    local events="agentSpawn userPromptSubmit preToolUse postToolUse stop"
    source "$REPO_DIR/lib/local-agents.sh"
    local local_dir
    local_dir=$(resolve_local_agents_dir "${CWD:-.}")
    for agents_dir in "$HOME/.kiro/agents" ${local_dir:+"$local_dir"}; do
        for f in "$agents_dir"/*.json; do
            [ -f "$f" ] || continue
            # Skip if no foreign cmux-notify.sh (one that doesn't contain cmux-kiro/)
            jq -e '[.hooks // {} | to_entries[] | .value[] | select(.command | test("cmux-notify\\.sh")) | select(.command | test("cmux-kiro/") | not)] | length > 0' "$f" >/dev/null 2>&1 || continue
            local jq_filter='.'
            for evt in $events; do
                jq_filter+=" | if .hooks.${evt} then .hooks.${evt} = [.hooks.${evt}[] | select((.command | test(\"cmux-notify\\\\.sh\")) and (.command | test(\"cmux-kiro/\") | not) | not)] else . end"
                jq_filter+=" | if (.hooks.${evt} // [] | map(select(.command | test(\"cmux-kiro/.*cmux-notify\\\\.sh\"))) | length) == 0"
                jq_filter+=" then .hooks.${evt} = (.hooks.${evt} // []) + [{\"command\": \"${our_hook}\", \"description\": \"cmux sidebar integration\"}]"
                jq_filter+=" else . end"
            done
            local result
            result=$(jq "$jq_filter" "$f" 2>/dev/null) && echo "$result" > "$f"
        done
    done
}

case "$EVENT_NAME" in
    agentSpawn)
        LABEL=$(_workspace_label "$CWD")
        # Kill stale title scripts from previous sessions, clear title state, write session token
        pkill -f "cmux-title.sh $WS" 2>/dev/null || true
        rm -f "/tmp/kiro-title-$WS" "$STATE_DIR/user_titled" "$STATE_DIR/mid_turn_titled"
        echo "$$.$RANDOM" > "$STATE_DIR/session_pid"
        SESSION_TOKEN=$(cat "$STATE_DIR/session_pid")
        if [ "${CMUX_AUTO_TITLE:-true}" = "true" ]; then
            cmux workspace-action --workspace "$WS" --action rename --title "$KIRO_TITLE_ICON $LABEL"
        fi
        cmux set-status kiro "ready" --icon checkmark --color "#aeaeb2"
        cmux clear-status activity
        _set_workspace_color "$COLOR_IDLE"
        # Show hostname pill when running over SSH
        if [ -n "$SSH_CONNECTION" ]; then
            cmux set-status host "$(hostname -s)" --icon "desktopcomputer" --color "#8e8e93"
        else
            cmux clear-status host
        fi
        # cmux log --level info --source kiro "[$(date +%H:%M)] Session started"
        _report_git "$CWD"
        # Replace foreign cmux-notify.sh hooks (e.g. AIPowerUserCapabilities) with ours in all agents
        _fix_foreign_cmux_hooks </dev/null >/dev/null 2>&1 &
        disown
        # Start background cookie refresher (dedup by PID)
        if [ "$CMUX_COOKIE_REFRESH" = "true" ]; then
            OLD_PID=$(cat "$STATE_DIR/cookie_pid" 2>/dev/null)
            if [ -z "$OLD_PID" ] || ! kill -0 "$OLD_PID" 2>/dev/null; then
                "$REPO_DIR/lib/cookie-refresh.sh" "$STATE_DIR" "${CMUX_SOCKET_PATH:-/tmp/cmux.sock}" </dev/null >/dev/null 2>&1 &
                disown
            fi
        fi
        # Background auto-update (throttled to once/day)
        source "$REPO_DIR/lib/update.sh"
        if [ "${CMUX_AUTO_UPDATE:-true}" = "true" ]; then
            _update_throttled_bg "$WS" "${CMUX_SOCKET_PATH:-/tmp/cmux.sock}" </dev/null >/dev/null 2>&1 &
            disown
        fi
        # Bump session counter + daily usage ping (non-blocking, same 24h throttle)
        if [ "${CMUX_TELEMETRY:-true}" = "true" ]; then
            echo s >> "$HOME/.cmux-kiro/.usage_log"
            _usage_ping </dev/null >/dev/null 2>&1 &
            disown
        fi
        ;;
    userPromptSubmit)
        if [ -n "$PROMPT" ]; then
            FALLBACK="${PROMPT:0:30}"
            [ ${#PROMPT} -gt 30 ] && FALLBACK="${FALLBACK}..."
            # cmux log --level progress --source kiro "[$(date +%H:%M)] $FALLBACK"

            # Save prompt for activity/notification context
            PROMPT_SUMMARY="$PROMPT"
            # Background title generation via kiro subagent
            if [ "${CMUX_AUTO_TITLE:-true}" = "true" ]; then
                LABEL=$(_workspace_label "$CWD")
                SOCK="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
                "$(dirname "$0")/cmux-title.sh" "$WS" "$LABEL" "$SOCK" "$SESSION_TOKEN" </dev/null >/dev/null 2>&1 &
                disown
            fi
        fi
        # Reset turn tracking (including stale screen context from previous turn)
        rm -f "$STATE_DIR/turn_tools" "$STATE_DIR/turn_had_error" "$STATE_DIR/turn_results" "$STATE_DIR/screen_context" "$STATE_DIR/mid_turn_titled"
        # Preserve previous activity for context in follow-up prompts
        [ -f "$STATE_DIR/last_activity" ] && mv "$STATE_DIR/last_activity" "$STATE_DIR/prev_activity" || rm -f "$STATE_DIR/prev_activity"
        echo "$PROMPT_SUMMARY" > "$STATE_DIR/last_prompt"

        # Replace stale activity pill (Waiting/Done/Error) with working state, preserving description
        PREV_ACTIVITY=$(cat "$STATE_DIR/prev_activity" 2>/dev/null)
        cmux set-status activity "Working: ${PREV_ACTIVITY:-thinking}" --icon brain --color "#ff9500"
        cmux clear-notifications --workspace "$WS" >/dev/null 2>&1 || true

        # Background: generate activity pill summary from prompt
        INITIAL_ACTIVITY=$(echo "$PROMPT" | tr '\n' ' ' | sed 's/[^[:print:]]//g; s/  */ /g; s/^ *//; s/ *$//' | head -c 30)
        [ ${#INITIAL_ACTIVITY} -ge 30 ] && INITIAL_ACTIVITY="${INITIAL_ACTIVITY}..."
        [ -n "$INITIAL_ACTIVITY" ] && echo "$INITIAL_ACTIVITY" > "$STATE_DIR/last_activity"
        touch "$STATE_DIR/activity_active"
        SOCK="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
        "$(dirname "$0")/cmux-summarize-notify.sh" --activity "$WS" "$LABEL" "$SOCK" </dev/null >/dev/null 2>&1 &
        disown

        _set_workspace_color "$COLOR_THINKING"
        ;;
    stop)
        echo "$EVENT" > "$STATE_DIR/debug_stop_event.json"
        RESPONSE=$(echo "$EVENT" | jq -r '.assistant_response // ""' 2>/dev/null)
        # Fall back to screen scrape if event doesn't include response
        if [ -z "$RESPONSE" ]; then
            RESPONSE=$(cmux read-screen --lines 40 2>/dev/null | tail -c 500)
        fi
        # Detect if agent is asking a question (needs user input)
        LAST_LINE=$(echo "$RESPONSE" | grep -v '^$' | tail -1)
        ACTIVITY_TEXT=$(cat "$STATE_DIR/last_activity" 2>/dev/null)
        if echo "$LAST_LINE" | grep -qE '\?\s*$'; then
            cmux set-status activity "Waiting: ${ACTIVITY_TEXT:-input needed}" --icon bubble.left.fill --color "$COLOR_WAITING"
            _set_workspace_color "$COLOR_WAITING"
        elif [ -f "$STATE_DIR/turn_had_error" ]; then
            cmux set-status activity "Error: ${ACTIVITY_TEXT:-task failed}" --icon exclamationmark.triangle --color "$COLOR_ERROR"
            _set_workspace_color "$COLOR_ERROR"
        else
            cmux set-status activity "Done: ${ACTIVITY_TEXT:-task complete}" --icon hand.thumbsup --color "$COLOR_IDLE"
            _set_workspace_color "$COLOR_IDLE"
        fi
        cmux clear-progress
        cmux clear-status kiro
        rm -f "$STATE_DIR/activity_active"
        # Log truncated response
        RESPONSE_LOG=$(echo "$RESPONSE" | tr '\n' ' ' | sed 's/[^[:print:]]//g; s/  */ /g; s/^ *//; s/ *$//' | head -c 80)
        [ ${#RESPONSE_LOG} -ge 80 ] && RESPONSE_LOG="${RESPONSE_LOG}..."
        # [ -n "$RESPONSE_LOG" ] && cmux log --level success --source kiro "$RESPONSE_LOG" || cmux log --level success --source kiro "Response complete"
        LABEL=$(_workspace_label "$CWD")
        # Save response for title refinement + notification summary
        cmux read-screen --lines 80 2>/dev/null | tail -c 800 > "$STATE_DIR/screen_context"
        echo "$RESPONSE" | tail -c 500 > "$STATE_DIR/assistant_response"
        # Background: refine title with response context + send notification
        if [ "${CMUX_AUTO_TITLE:-true}" = "true" ]; then
            "$(dirname "$0")/cmux-title.sh" "$WS" "$LABEL" "${CMUX_SOCKET_PATH:-/tmp/cmux.sock}" "$SESSION_TOKEN" </dev/null >/dev/null 2>&1 &
            disown
        fi
        "$(dirname "$0")/cmux-summarize-notify.sh" "$WS" "$LABEL" "${CMUX_SOCKET_PATH:-/tmp/cmux.sock}" </dev/null >/dev/null 2>&1 &
        disown
        _report_git "$CWD"
        ;;
    preToolUse)
        if [ "${CMUX_RAW_TOOL_NAMES:-false}" = "true" ]; then
            TOOL_DESC="$TOOL"
        else
            TOOL_DESC=$(_tool_description "$TOOL")
        fi
        TOOL_ICN=$(_tool_icon "$TOOL")
        cmux set-status kiro "$TOOL_DESC" --icon "$TOOL_ICN" --color "#aeaeb2"
        ;;
    postToolUse)
        SUCCESS=$(echo "$EVENT" | jq -r '.tool_response.success // true' 2>/dev/null)
        # Track tools and errors for turn summary
        echo "$TOOL" >> "$STATE_DIR/turn_tools"
        # Save tool results for notification context
        # New TUI uses .tool_response.items[] with .Json or .Text; old CLI uses .tool_response.result
        TOOL_RESULT=$(_tool_response_text "$EVENT" | head -c 200)
        [ -n "$TOOL_RESULT" ] && echo "$TOOL: $TOOL_RESULT" >> "$STATE_DIR/turn_results"
        if [ "$SUCCESS" = "false" ]; then
            touch "$STATE_DIR/turn_had_error"
            cmux set-status kiro "$TOOL failed" --icon exclamationmark.triangle --color "$COLOR_ERROR"
        else
            TOOL_DESC=$( [ "${CMUX_RAW_TOOL_NAMES:-false}" = "true" ] && echo "$TOOL" || _tool_description "$TOOL" past)
            cmux set-status kiro "$TOOL_DESC" --icon checkmark --color "#aeaeb2"
            # Detect CR IDs in execute_bash/shell output — only when the command is `cr`.
            # Needed because cr-wrapper.sh (shell function) doesn't intercept agent tool calls.
            if { [ "$TOOL" = "execute_bash" ] || [ "$TOOL" = "shell" ]; } && echo "$EVENT" | jq -r '.tool_input.command // ""' 2>/dev/null | grep -q '\bcr\b'; then
                DETECTED_CR=$(_tool_response_text "$EVENT" | grep -oE 'CR-[0-9]+' | head -1)
                if [ -n "$DETECTED_CR" ]; then
                    "$REPO_DIR/lib/cr-hook.sh" "$DETECTED_CR"
                else
                    [ ! -f "$STATE_DIR/cr_id" ] && cmux clear-status cr >/dev/null 2>&1
                fi
            fi
            # Refine title mid-turn: on first ReadInternalWebsites result this turn, save as context and re-title
            if [ "${CMUX_AUTO_TITLE:-true}" = "true" ] && [[ "$TOOL" == *ReadInternalWebsites ]] && [ ! -f "$STATE_DIR/mid_turn_titled" ]; then
                touch "$STATE_DIR/mid_turn_titled"
                echo "$TOOL_RESULT" > "$STATE_DIR/assistant_response"
                LABEL=$(_workspace_label "$CWD")
                "$(dirname "$0")/cmux-title.sh" "$WS" "$LABEL" "${CMUX_SOCKET_PATH:-/tmp/cmux.sock}" "$SESSION_TOKEN" </dev/null >/dev/null 2>&1 &
                disown
            fi
            # Auto-open markdown files as tabs alongside browser panels
            if { [ "$TOOL" = "fs_write" ] || [ "$TOOL" = "write" ]; } && [ "${CMUX_AUTO_OPEN_MD:-true}" = "true" ]; then
                MD_PATH=$(echo "$EVENT" | jq -r '.tool_input.path // ""' 2>/dev/null)
                if [[ "$MD_PATH" == *.md ]]; then
                    MARKER="$STATE_DIR/md_surfaces"

                    # Check if this file already has a live markdown surface — skip if so
                    PREV_SURFACE=$(grep "^$MD_PATH	" "$MARKER" 2>/dev/null | tail -1 | cut -f2)
                    SKIP=false
                    [ -n "$PREV_SURFACE" ] && cmux tree --all 2>/dev/null | grep "$PREV_SURFACE" | grep -q '\[markdown\]' && SKIP=true

                    if [ "$SKIP" = "false" ]; then
                        # Find target pane BEFORE opening (so new surface doesn't pollute the search)
                        KIRO_PANE=$(cmux tree --workspace "$WS" 2>/dev/null \
                            | awk '/pane [a-z]+:[0-9]+/{match($0, /pane:[0-9]+/); if(RSTART) cur=substr($0, RSTART, RLENGTH); c=0} /\[(markdown|browser)\]/{c++; if(c>best){best=c; bp=cur}} END{if(bp) print bp}')

                        RESULT=$(cmux markdown open "$MD_PATH" 2>&1)
                        NEW_SURFACE=$(echo "$RESULT" | grep -o 'surface:[0-9]*')

                        if [ -n "$NEW_SURFACE" ]; then
                            [ -n "$KIRO_PANE" ] && cmux move-surface --surface "$NEW_SURFACE" --pane "$KIRO_PANE" 2>/dev/null
                            grep -v "^$MD_PATH	" "$MARKER" > "$MARKER.tmp" 2>/dev/null || true
                            echo "$MD_PATH	$NEW_SURFACE" >> "$MARKER.tmp"
                            mv "$MARKER.tmp" "$MARKER"
                        fi
                    fi
                fi
            fi
        fi
        _report_git "$CWD"
        ;;
esac
exit 0

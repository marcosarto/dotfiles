#!/bin/bash
# Interactive onboarding tour — demos kiro-cmux features live in the sidebar
# Called from setup.sh on first install (when running inside cmux)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SOCKET="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
TAB="${CMUX_TAB_ID:-$CMUX_WORKSPACE_ID}"

# If not inside cmux, try to launch it with the tour
if [ ! -S "$SOCKET" ] || [ -z "$TAB" ]; then
    if [[ "$(uname)" == "Darwin" ]] && [ -d "/Applications/cmux.app" ]; then
        echo -e "${BOLD}Not inside cmux${NC} — opening cmux with the tour..."
        open -a cmux
        _tour_sock=""
        for _i in $(seq 1 10); do
            for _s in "$HOME/Library/Application Support/cmux/cmux.sock" "/tmp/cmux.sock"; do
                [ -S "$_s" ] && _tour_sock="$_s" && break 2
            done
            sleep 0.5
        done
        if [ -n "$_tour_sock" ]; then
            _tour_ws=$(CMUX_SOCKET_PATH="$_tour_sock" cmux new-workspace --name "✨ Welcome" --command "kmux tour; exec ${SHELL:-zsh}" 2>/dev/null | grep -o 'workspace:[0-9]*')
            if [ -n "$_tour_ws" ]; then
                CMUX_SOCKET_PATH="$_tour_sock" cmux select-workspace --workspace "$_tour_ws" >/dev/null 2>&1
                echo -e "${GREEN}✓${NC} Tour launched in cmux"
            else
                echo -e "cmux opened but socket access was denied."
                echo -e "Run ${BOLD}kmux tour${NC} inside a cmux terminal."
            fi
        else
            echo -e "cmux opened — run ${BOLD}kmux tour${NC} in a cmux terminal"
        fi
    else
        echo -e "${BOLD}kmux tour${NC} needs to run inside a cmux workspace."
        echo "Open cmux.app and run this command in a cmux terminal."
    fi
    exit 0
fi

# Use raw socket for everything — cmux CLI hangs in background subshells
_sock() { echo "$1" | nc -w 1 -U "$SOCKET" >/dev/null 2>&1 || true; }
_pill() { _sock "set_status $1 $2 --icon=$3 --color=$4 --tab=$TAB"; }
_clear() { _sock "clear_status $1 --tab=$TAB"; }
_title() {
    printf '{"id":"r","method":"workspace.rename","params":{"workspace_id":"%s","title":"%s"}}\n' "$TAB" "$1" \
        | nc -w 1 -U "$SOCKET" >/dev/null 2>&1 || true
}
_color() {
    printf '{"id":"c","method":"workspace.action","params":{"workspace_id":"%s","action":"set-color","color":"%s"}}\n' "$TAB" "$1" \
        | nc -w 1 -U "$SOCKET" >/dev/null 2>&1 || true
}
_notify() {
    # v1 notify_target: workspace surface title|subtitle|body
    echo "notify_target $TAB ${CMUX_SURFACE_ID:-$TAB} $1|$2|$3" \
        | nc -w 1 -U "$SOCKET" >/dev/null 2>&1 || true
}

_clear_pills() {
    _clear kiro; _clear activity; _clear task; _clear cr
}

# Save original title to restore at end
ORIG_TITLE=""
ORIG_TITLE=$(echo '{"id":"t","method":"workspace.list","params":{}}' \
    | nc -w 1 -U "$SOCKET" 2>/dev/null \
    | jq -r --arg ws "$TAB" '.result.workspaces[]? | select(.ref == $ws or .id == $ws) | .title // empty' 2>/dev/null) || true

_bg_pid=""
_stop_bg() {
    [ -n "$_bg_pid" ] && kill "$_bg_pid" 2>/dev/null
    wait "$_bg_pid" 2>/dev/null
    _bg_pid=""
}
_start_bg() { "$1" & _bg_pid=$!; }

_cleanup() {
    _stop_bg
    _clear_pills
    rm -f /tmp/kiro-tour-*.md
    printf '{"id":"c","method":"workspace.action","params":{"workspace_id":"%s","action":"clear-color"}}\n' "$TAB" \
        | nc -w 1 -U "$SOCKET" >/dev/null 2>&1 || true
    [ -n "$ORIG_TITLE" ] && _title "$ORIG_TITLE"
}
trap '_cleanup' EXIT

_pause() {
    echo ""
    echo -ne "  ${DIM}press enter to continue${NC}"
    read -r
    echo -ne "\033[1A\033[2K"
    _stop_bg
}

# --- Background animation loops (all use raw socket) ---

_loop_titles() {
    local titles=(
        "◆ Fix auth token refresh"
        "◆ Implement OAuth2 token rotation"
        "◆ Add retry logic to token refresh"
        "◆ Refactor auth module for testability"
        "◆ Debug flaky integration tests"
        "◆ Migrate DynamoDB to single-table"
        "◆ Add CloudWatch alarms for latency"
        "◆ Review CR-12345678"
        "◆ Investigate DLQ backlog"
        "◆ Write onboarding docs"
    )
    local i=0
    while true; do
        _title "${titles[$i]}"
        i=$(( (i + 1) % ${#titles[@]} ))
        sleep 1.2
    done
}

_loop_tools() {
    while true; do
        _pill kiro "Searching codebase" magnifyingglass "#aeaeb2"; sleep 1.2
        _pill kiro "Searched codebase" checkmark "#aeaeb2"; sleep 0.6
        _pill kiro "Reading auth.ts" doc.text "#aeaeb2"; sleep 1.2
        _pill kiro "Read auth.ts" checkmark "#aeaeb2"; sleep 0.6
        _pill kiro "Writing auth.ts" pencil "#aeaeb2"; sleep 1.2
        _pill kiro "Wrote auth.ts" checkmark "#aeaeb2"; sleep 0.6
        _pill kiro "Running tests" terminal "#aeaeb2"; sleep 1.2
        _pill kiro "Ran tests" checkmark "#aeaeb2"; sleep 0.6
    done
}

_loop_lifecycle() {
    while true; do
        _color "#ff9500"
        _pill activity "Working: Implementing auth refresh" quote.bubble "#ff9500"
        sleep 1.5
        _color "#bf5af2"
        _pill activity "Waiting: Implementing auth refresh" bubble.left.fill "#bf5af2"
        sleep 1.5
        _color "#30d158"
        _pill activity "Done: Implementing auth refresh" hand.thumbsup "#30d158"
        sleep 1.5
    done
}

# --- Tour ---

_title "✨ Welcome to kiro-cmux"

echo ""
echo -e "${BOLD}✨ Quick Tour${NC} ${DIM}(~1 minute — watch the sidebar ←)${NC}"
echo ""
echo -e "  kiro-cmux turns your sidebar into a live AI dashboard."
echo -e "  Let's see what it does."
_pause

# 1. AI workspace titles
echo -e "  ${CYAN}1/7${NC}  ${BOLD}AI workspace titles${NC} — know what each tab is doing"
_start_bg _loop_titles
echo -e "       Each workspace gets an AI-generated title from your prompt."
echo -e "       Titles refine as the task evolves — watch it change ←"
_pause
_title "◆ Implement OAuth2 token rotation"

# 2. Live tool narration
echo -e "  ${CYAN}2/7${NC}  ${BOLD}Live tool narration${NC} — see what Kiro is doing at a glance"
_color "#ff9500"
_start_bg _loop_tools
echo -e "       Every tool call is narrated in the sidebar — searching,"
echo -e "       reading, writing, running commands. Watch it cycle ←"
_pause
_clear kiro

# 3. Turn lifecycle states
echo -e "  ${CYAN}3/7${NC}  ${BOLD}Turn lifecycle${NC} — working, waiting, done"
_start_bg _loop_lifecycle
echo ""
echo -e "       ${YELLOW}●${NC} ${BOLD}Working${NC} (orange) — Kiro is thinking or using tools"
echo -e "       ${PURPLE}●${NC} ${BOLD}Waiting${NC} (purple) — Kiro asked you a question"
echo -e "       ${GREEN}●${NC} ${BOLD}Done${NC}    (green)  — turn completed successfully"
echo ""
echo -e "       Watch the sidebar cycle through each state ←"
_pause
_clear kiro; _clear activity; _color "#30d158"

# 4. Task & CR detection
echo -e "  ${CYAN}4/7${NC}  ${BOLD}Task & CR detection${NC} — auto-pinned to the sidebar"
_sock "set_status task CMUX-42 --icon=tag --color=#64d2ff --url=https://issues.amazon.com/issues/CMUX-42 --tab=$TAB"
sleep 0.8
_sock "set_status cr CR-12345678 --icon=arrow.triangle.branch --color=#0a84ff --url=https://code.amazon.com/reviews/CR-12345678 --tab=$TAB"
echo -e "       Mention a SIM/task in your prompt → pinned to the sidebar."
echo -e "       Create a CR → detected and pinned automatically."
echo -e "       Both are clickable — click to open in a browser panel."
_pause

# 5. Smart notifications
echo -e "  ${CYAN}5/7${NC}  ${BOLD}Smart notifications${NC} — AI-summarized when Kiro finishes"
_pill activity "Implementing auth refresh" hand.thumbsup "#30d158"
_notify "✅ Kiro" "Implement OAuth2 token rotation" "Updated 3 files, added error handling, all tests passing"
echo -e "       When a turn completes, you get a desktop notification with"
echo -e "       an AI summary of what happened — not just \"Response complete\"."
echo -e "       Click the notification to jump to that workspace."
_pause

# 6. Markdown panels
echo -e "  ${CYAN}6/7${NC}  ${BOLD}Live markdown panels${NC} — rendered docs in the sidebar"
TOUR_MD=$(mktemp /tmp/kiro-tour-XXXXXX.md)

echo "" > "$TOUR_MD"
cmux markdown open "$TOUR_MD" >/dev/null 2>&1 || true
sleep 0.5

_loop_markdown() {
    _md() { printf '%s\n' "$@" >> "$TOUR_MD"; }
    _md "# 👋 Hello from a markdown panel"; sleep 1.1
    _md "" "This file didn't exist a second ago."; sleep 0.9
    _md "" "I'm being written to **right now**, line by line."; sleep 0.9
    _md "" "Every time a new line lands, cmux re-renders me instantly."; sleep 1.1
    _md "" "---" "" "## Why this matters" ""; sleep 0.7
    _md "When Kiro writes a plan, a changelog, or a doc —"; sleep 0.7
    _md "you see it appear here in real time. No refresh needed."; sleep 1.1
    _md "" "---" "" "## Watch this part closely" ""; sleep 0.9
    _md "Loading something cool..."; sleep 0.4
    _md "" '```' '  ╔══════════════════════════════════╗' '  ║                                  ║' '  ║   You are looking at live reload  ║' '  ║                                  ║' '  ║   It just happened. ✨            ║' '  ║                                  ║' '  ╚══════════════════════════════════╝' '```'
    sleep 1.1
    _md "" "---" "" "*Press enter in the terminal to continue.*"
    # Keep alive so _stop_bg has something to kill
    sleep 999
}
_start_bg _loop_markdown
echo -e "       ← Watch the panel write itself in real time."
echo -e "       Kiro writes plans and docs the same way — you see"
echo -e "       every line appear as it's written."
_pause
# Close the markdown panel
_MD_SURF=$(cmux tree 2>/dev/null | grep '\[markdown\]' | grep -o 'surface:[0-9]*' | tail -1)
if [ -n "$_MD_SURF" ]; then
    cmux close-surface --surface "$_MD_SURF" >/dev/null 2>&1 || true
fi
rm -f "$TOUR_MD"

# 7. Browser panels
echo -e "  ${CYAN}7/7${NC}  ${BOLD}Authenticated browser panels${NC} — internal sites in the sidebar"
echo -e "       Kiro can open Phonetool, SIM, Code Browser, and other internal"
echo -e "       sites right in cmux — with automatic SSO authentication."
echo -e "       No need to switch to a browser or run mwinit again."
_pause

# Cleanup handled by EXIT trap
# Telemetry — tour completed (respects CMUX_TELEMETRY opt-out)
INSTALL_DIR="${HOME}/.cmux-kiro"
[ -f "$HOME/.config/cmux-kiro/config" ] && source "$HOME/.config/cmux-kiro/config"
if [ "${CMUX_TELEMETRY:-true}" = "true" ]; then
    curl -s -X POST "https://hooks.slack.com/triggers/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" \
        -H 'Content-Type: application/json' \
        -d "{\"alias\":\"$(whoami)\",\"version\":\"$(cat "$INSTALL_DIR/VERSION" 2>/dev/null)\",\"event\":\"tour\",\"status\":\"completed\",\"sessions\":0,\"notifications\":0}" \
        >/dev/null 2>&1 &
fi

echo -e "  ${GREEN}That's it!${NC} All of this happens automatically when you use Kiro."
echo -e "  Just type ${BOLD}k${NC} in this terminal to start."
echo ""
echo -e "  ${BOLD}Before you go:${NC}"
echo -e "  • Make sure automation is enabled:"
echo -e "    cmux Settings (⌘,) → Socket Control → Automation mode"
echo -e "  • Enable desktop notifications:"
echo -e "    System Settings → Notifications → cmux → Allow Notifications"
echo ""
echo -e "  ${DIM}kmux update${NC}             ${DIM}check for updates${NC}"
echo -e "  ${DIM}kmux doctor${NC}             ${DIM}diagnose issues${NC}"
echo -e "  ${DIM}kmux tour${NC}               ${DIM}re-run this tour${NC}"
echo -e "  ${DIM}kmux setup --remove-hooks${NC}  ${DIM}uninstall${NC}"
echo -e "  ${DIM}#cmux-interest on Slack${NC}    ${DIM}feedback${NC}"
echo ""

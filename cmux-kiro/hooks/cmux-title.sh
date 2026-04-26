#!/bin/bash
set +e
# Ensure kiro-cli is findable in background processes (not sourced from .zshrc)
export PATH="$PATH:$HOME/.local/bin:$HOME/bin"
WS="$1" LABEL="$2" SOCK="${3:-/tmp/cmux.sock}" MY_SESSION_PID="$4"
TITLE_FILE="/tmp/kiro-title-$WS"
STATE_DIR="/tmp/kiro-cmux-$WS"

TAB="$CMUX_TAB_ID"
unset CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_PANEL_ID CMUX_SOCKET_PATH CMUX_SURFACE_ID

# User manually titled this workspace — skip auto-titling (still process task/CR pills below)
USER_TITLED=false
[ -f "$STATE_DIR/user_titled" ] && USER_TITLED=true

# Also detect mid-session renames: if cmux title differs from what we last set, user changed it
if [ "$USER_TITLED" = "false" ]; then
    LIVE_TITLE=$(printf '{"id":"t","method":"workspace.list","params":{}}\n' \
        | nc -w 1 -U "$SOCK" 2>/dev/null \
        | jq -r --arg ws "$WS" '.result.workspaces[] | select(.ref == $ws or .id == $ws) | .title' 2>/dev/null)
    OUR_LAST=$(cat "$TITLE_FILE" 2>/dev/null)
    if [ -n "$LIVE_TITLE" ] && [ -n "$OUR_LAST" ] && [ "$LIVE_TITLE" != "◆ $OUR_LAST" ]; then
        touch "$STATE_DIR/user_titled"
        USER_TITLED=true
    fi
fi

CURRENT=$(cat "$TITLE_FILE" 2>/dev/null)
PROMPT=$(cat "$STATE_DIR/last_prompt" 2>/dev/null)
SCREEN=$(cat "$STATE_DIR/screen_context" 2>/dev/null)
[ -z "$SCREEN" ] && SCREEN=$(cat "$STATE_DIR/assistant_response" 2>/dev/null)

if [ -z "$CURRENT" ]; then
    MSG="Title this task:
Prompt: ${PROMPT:-unknown}
${SCREEN:+Assistant response: $SCREEN}"
else
    if [ -n "$SCREEN" ]; then
        MSG="Current title: $CURRENT
New prompt: ${PROMPT:-unknown}
Assistant response: $SCREEN
If the assistant response reveals what the task is actually about, output a better title. A title that just contains a ticket ID (like \"Fix SIM-12345\" or \"Plan CMUX-8\") is NOT descriptive — replace it with what the work is. Only output SAME if the title already describes the work."
    else
        MSG="Current title: $CURRENT
New prompt: ${PROMPT:-unknown}
Output SAME if this continues the same task. Output a new title if this is a completely different topic."
    fi
fi

RAW=$(KASK_AGENT=cmux-titler python3 ~/bin/kiro-acp-client.py "$MSG" 2>/dev/null)
JSON=$(echo "$RAW" | sed 's/```json//; s/```//' | tr '\n' ' ' | grep -o '{[^}]*}' | head -1)

ACTION=$(echo "$JSON" | jq -r '.action // empty' 2>/dev/null)
TITLE=$(echo "$JSON" | jq -r '.title // empty' 2>/dev/null)
TASK=$(echo "$JSON" | jq -r '.task // empty' 2>/dev/null)
[ "$TASK" = "null" ] && TASK=""
# CR IDs are detected from actual `cr` output, not AI — reject any CR- variant
if echo "$TASK" | grep -qiE '^CR-'; then
    TASK=""
fi

if [ "$ACTION" = "SAME" ]; then
    # Still update task pills even when title unchanged
    TITLE=""
else
    [ -z "$TITLE" ] && { [ -z "$CURRENT" ] && TITLE="$LABEL" || true; }
fi

[ -n "$TITLE" ] && [ "$USER_TITLED" = "false" ] && {
    # Abort if a new session started while we were waiting for kask
    CUR_PID=$(cat "$STATE_DIR/session_pid" 2>/dev/null)
    [ -n "$MY_SESSION_PID" ] && [ "$CUR_PID" != "$MY_SESSION_PID" ] && exit 0
    echo "$TITLE" > "$TITLE_FILE"
    printf '{"id":"rename","method":"workspace.rename","params":{"workspace_id":"%s","title":"◆ %s"}}\n' "$WS" "$TITLE" \
        | nc -w 1 -U "$SOCK" >/dev/null 2>&1
}

# Manage task pill (use socket directly for --url support)
_set_status() {
    echo "set_status $1 $2 --icon=$3 --color=$4 --url=$5 --tab=$TAB" | nc -w 1 -U "$SOCK" >/dev/null 2>&1
}
_clear_status() {
    echo "clear_status $1 --tab=$TAB" | nc -w 1 -U "$SOCK" >/dev/null 2>&1
}

_task_url() {
    case "$1" in
        CR-*) echo "https://code.amazon.com/reviews/$1" ;;
        *)    echo "https://issues.amazon.com/issues/$1" ;;
    esac
}

PREV_TASK=$(cat "$STATE_DIR/task_id" 2>/dev/null)
if [ -n "$TASK" ] && [ "$TASK" != "$PREV_TASK" ]; then
    echo "$TASK" > "$STATE_DIR/task_id"
    _set_status task "$TASK" tag "#64d2ff" "$(_task_url "$TASK")"
    # New task detected — clear stale CR from previous task
    if [ -n "$PREV_TASK" ]; then
        rm -f "$STATE_DIR/cr_id"
        _clear_status cr
    fi
fi

# CR pill: set by cr-hook.sh (postToolUse + cr-wrapper.sh), cleared above
# only when a different task ID is detected (task change = CR no longer relevant).
# Title refinements within the same task preserve the CR.

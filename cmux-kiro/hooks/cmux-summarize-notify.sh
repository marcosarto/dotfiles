#!/bin/bash
set +e
# Ensure kiro-cli is findable in background processes (not sourced from .zshrc)
export PATH="$PATH:$HOME/.local/bin:$HOME/bin"
[ -f "$HOME/.config/cmux-kiro/config" ] && source "$HOME/.config/cmux-kiro/config"

ACTIVITY_MODE=false
if [ "$1" = "--activity" ]; then
    ACTIVITY_MODE=true
    shift
fi

WS="$1" LABEL="$2" SOCK="${3:-/tmp/cmux.sock}"
STATE_DIR="/tmp/kiro-cmux-$WS"
SURFACE="$CMUX_SURFACE_ID"

unset CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_PANEL_ID CMUX_SOCKET_PATH CMUX_SURFACE_ID

LAST_PROMPT=$(cat "$STATE_DIR/last_prompt" 2>/dev/null)
# Extract task IDs from URLs before stripping paths, so "https://taskei.amazon.dev/tasks/CMUX-9" → "CMUX-9"
CLEAN_PROMPT=$(echo "$LAST_PROMPT" | sed 's|https*://[^ ]*/tasks/\([A-Za-z]*-[0-9]*\)|\1|g; s|https*://[^ ]*||g')

if [ "$ACTIVITY_MODE" = "true" ]; then
    PREV_ACTIVITY=$(cat "$STATE_DIR/prev_activity" 2>/dev/null)
    MSG="IMPORTANT: Each request is independent. Do NOT reference any previous requests or responses in this conversation.

Generate a short present-tense activity description for what this AI assistant is working on.

${PREV_ACTIVITY:+Previous task: $PREV_ACTIVITY
}User asked: ${CLEAN_PROMPT:-unknown}

RULES:
- Present tense, describing the objective of this task
- HARD LIMIT: 30 characters maximum. This is strict — count carefully.
- Omit filenames, paths, and details to stay under 30 chars
- Prefer short verbs: Fix, Add, Update, Research, Implement, Check
- If the user prompt is ONLY a confirmation word (yes, ok, do it, go ahead, sure) with no other content, use the \"Previous task\" field above. If there is no \"Previous task\" field either, respond with {\"activity\":\"\"}
- Any prompt that asks a question or describes a task is NOT a confirmation — always generate an activity for it
- Examples: \"Implementing auth refresh\", \"Fixing auth module tests\", \"Researching SIM-1234\", \"Checking jq version\"

Respond with ONLY: {\"activity\":\"...\"}"

    RAW=$(KASK_AGENT=cmux-activity python3 ~/bin/kiro-acp-client.py "$MSG" 2>/dev/null)
    JSON=$(echo "$RAW" | sed 's/```json//; s/```//' | tr '\n' ' ' | grep -o '{[^}]*}' | head -1)
    ACTIVITY=$(echo "$JSON" | jq -r '.activity // empty' 2>/dev/null)

    [ -z "$ACTIVITY" ] && exit 0
    # Don't update if the turn already ended
    [ ! -f "$STATE_DIR/activity_active" ] && exit 0

    export CMUX_SOCKET_PATH="$SOCK" CMUX_WORKSPACE_ID="$WS" CMUX_SURFACE_ID="$SURFACE"
    cmux set-status activity "Working: $ACTIVITY" --icon quote.bubble --color "#ff9500"
    echo "$ACTIVITY" > "$STATE_DIR/last_activity"
else
    TOOLS_LOG=$(cat "$STATE_DIR/turn_tools" 2>/dev/null)
    HAD_ERROR=""
    [ -f "$STATE_DIR/turn_had_error" ] && HAD_ERROR="Some tools failed."

    RESPONSE=$(cat "$STATE_DIR/assistant_response" 2>/dev/null)
    if [ -n "$RESPONSE" ]; then
        RESPONSE_LABEL="Assistant response"
    else
        RESPONSE=$(cat "$STATE_DIR/screen_context" 2>/dev/null)
        RESPONSE_LABEL="Terminal output (may contain UI noise — extract the assistant's actual answer)"
    fi

    MSG="Summarize this AI assistant turn for a desktop notification.

User asked: ${CLEAN_PROMPT:-unknown}
Tools used: ${TOOLS_LOG:-none}
${HAD_ERROR}
${RESPONSE:+${RESPONSE_LABEL}: $RESPONSE}

RULES:
- If the ASSISTANT RESPONSE (not the user's question) ends with a question to the user or offers choices, the body MUST start with \"Waiting:\" followed by the question/choice summary
- If the assistant completed the task and gave an answer, the body MUST include the concrete result (numbers, names, outcomes) — not just describe what tools ran
- Body must be ONE short sentence (under 120 chars)
- Title must be 2-4 words

Respond with ONLY: {\"title\":\"...\",\"body\":\"...\"}"

    RAW=$(KASK_AGENT=cmux-notifier python3 ~/bin/kiro-acp-client.py "$MSG" 2>/dev/null)
    JSON=$(echo "$RAW" | sed 's/```json//; s/```//' | tr '\n' ' ' | grep -o '{[^}]*}' | head -1)

    NTITLE=$(echo "$JSON" | jq -r '.title // empty' 2>/dev/null)
    NBODY=$(echo "$JSON" | jq -r '.body // empty' 2>/dev/null)

    [ -z "$NTITLE" ] && NTITLE="Response Complete"
    [ -z "$NBODY" ] && NBODY="Kiro finished and is waiting for your input."

    ICON="✅"
    case "$NBODY" in Waiting:*) ICON="⚠️"; NTITLE="Needs Input: $NTITLE" ;; esac
    [ -n "$HAD_ERROR" ] && ICON="❗"

    export CMUX_SOCKET_PATH="$SOCK" CMUX_WORKSPACE_ID="$WS" CMUX_SURFACE_ID="$SURFACE"
    cmux notify --title "$ICON $NTITLE" --body "$NBODY" --workspace "$WS"
    # Bump notification counter for daily usage ping
    [ "${CMUX_TELEMETRY:-true}" = "true" ] && echo n >> "$HOME/.cmux-kiro/.usage_log"
fi

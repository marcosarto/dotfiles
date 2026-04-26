#!/bin/bash
# Hook eligible agents with cmux-notify.sh
# Usage:
#   lib/hook-agents.sh                    # hook all eligible agents
#   lib/hook-agents.sh --interactive      # interactive checkbox picker
#   lib/hook-agents.sh gpu-coder          # hook specific agent by name
#   lib/hook-agents.sh 'gpu-*'           # glob pattern match
#   lib/hook-agents.sh gpu-coder builder  # multiple names/patterns
#
# Shared by setup.sh and `kmux hook`.

set -e

INSTALL_DIR="${CMUX_KIRO_INSTALL_DIR:-$HOME/.cmux-kiro}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

source "$REPO_DIR/lib/local-agents.sh"

# --- Helper: check if agent has cmux hooks ---
has_all_cmux_hooks() {
    local f="$1"
    local count
    count=$(jq '[.hooks.agentSpawn, .hooks.userPromptSubmit, .hooks.preToolUse, .hooks.postToolUse, .hooks.stop | select(. != null) | map(select(.command | test("cmux-kiro/.*cmux-notify\\.sh"))) | select(length > 0)] | length' "$f" 2>/dev/null)
    [ "$count" -eq 5 ]
}

# --- Core: inject hooks into a newline-separated list of agent files ---
inject_cmux_hooks() {
    local selected="$1"
    local local_dir="$2"
    local hook_cmd="$INSTALL_DIR/hooks/cmux-notify.sh"
    local events="agentSpawn userPromptSubmit preToolUse postToolUse stop"
    local updated=0

    while IFS= read -r agent_file; do
        [ -f "$agent_file" ] || continue
        local display_name
        display_name=$(agent_display_name "$agent_file" "$local_dir")

        if ! jq empty "$agent_file" 2>/dev/null; then
            warn "Skipped $display_name (invalid JSON)" >&2
            continue
        fi

        if has_all_cmux_hooks "$agent_file"; then
            continue
        fi

        local jq_filter='. | if .hooks == null then .hooks = {} else . end'
        for evt in $events; do
            jq_filter+=" | if .hooks.${evt} then .hooks.${evt} = [.hooks.${evt}[] | select((.command | test(\"cmux-notify\\\\.sh\")) and (.command | test(\"cmux-kiro/\") | not) | not)] else . end"
            jq_filter+=" | if (.hooks.${evt} // [] | map(select(.command | test(\"cmux-kiro/.*cmux-notify\\\\.sh\"))) | length) == 0"
            jq_filter+=" then .hooks.${evt} = (.hooks.${evt} // []) + [{\"command\": \"${hook_cmd}\", \"description\": \"cmux sidebar integration\"}]"
            jq_filter+=" else . end"
        done

        local result
        if result=$(jq "$jq_filter" "$agent_file" 2>/dev/null); then
            echo "$result" > "$agent_file"
            info "Hooked $display_name" >&2
            ((updated++)) || true
        else
            warn "Skipped $display_name (jq failed)" >&2
        fi
    done <<< "$selected"

    echo "$updated"
}

# --- Build list of eligible agents ---
build_eligible_agents() {
    local local_dir="$1"
    local skip_agents="cmux.json cmux-titler.json cmux-notifier.json fast.json cmux-activity.json"
    ELIGIBLE_AGENTS=()
    ELIGIBLE_DISPLAY=()
    for dir in "$HOME/.kiro/agents" ${local_dir:+"$local_dir"}; do
        for f in "$dir"/*.json; do
            [ -f "$f" ] || continue
            bn=$(basename "$f")
            echo "$skip_agents" | grep -qw "$bn" && continue
            if [ -L "$f" ]; then
                target=$(readlink "$f" 2>/dev/null)
                echo "$target" | grep -q "AmznCmuxKiroTools\|cmux-kiro" && continue
            fi
            jq empty "$f" 2>/dev/null || continue
            has_all_cmux_hooks "$f" && continue
            ELIGIBLE_AGENTS+=("$f")
            ELIGIBLE_DISPLAY+=("$(agent_display_name "$f" "$local_dir")")
        done
    done
}

# --- Backup agents before modification ---
backup_agents() {
    local local_dir="$1"
    shift
    local agents=("$@")

    # Backup global agents (only if any selected are global)
    for f in "${agents[@]}"; do
        if [ -z "$local_dir" ] || [[ "$f" != "$local_dir"/* ]]; then
            if [ -d "$HOME/.kiro/agents" ]; then
                local backup_dir="$HOME/.kiro/agents.backup.$(date +%Y%m%d%H%M%S)"
                if ! cp -r ~/.kiro/agents/ "$backup_dir"; then
                    warn "Failed to create global backup — aborting"
                    exit 1
                fi
                info "Backup created at $backup_dir"
            fi
            break
        fi
    done
    # Backup local agents (only if any selected are local)
    if [ -n "$local_dir" ]; then
        for f in "${agents[@]}"; do
            if [[ "$f" == "$local_dir"/* ]]; then
                local local_backup="$PWD/.kiro/agents.backup.$(date +%Y%m%d%H%M%S)"
                if ! cp -r "$local_dir/" "$local_backup"; then
                    warn "Failed to create local backup — aborting"
                    exit 1
                fi
                info "Local backup at $local_backup"
                break
            fi
        done
    fi
}

# --- Interactive picker ---
run_interactive() {
    local local_dir="$1"
    build_eligible_agents "$local_dir"

    if [ "${#ELIGIBLE_AGENTS[@]}" -eq 0 ]; then
        info "All agents already have cmux hooks"
        return 0
    fi

    CHECKED=()
    for i in "${!ELIGIBLE_AGENTS[@]}"; do CHECKED[$i]=1; done
    CURSOR=0
    COUNT=${#ELIGIBLE_AGENTS[@]}

    draw_menu() {
        if [ "${DRAWN:-0}" -eq 1 ]; then
            printf '\033[%dA' "$((COUNT + 1))"
        fi
        for i in "${!ELIGIBLE_AGENTS[@]}"; do
            local marker="[ ]"
            [ "${CHECKED[$i]}" -eq 1 ] && marker="[x]"
            local prefix="  "
            [ "$i" -eq "$CURSOR" ] && prefix="▸ "
            printf '\033[2K%s%s %s\n' "$prefix" "$marker" "${ELIGIBLE_DISPLAY[$i]}"
        done
        printf '\033[2K  ↑↓ move · space toggle · a all · n none · enter confirm\n'
        DRAWN=1
    }

    echo "  Select agents to add cmux hooks to:"
    draw_menu

    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b') read -rsn2 seq
                case "$seq" in
                    '[A') ((CURSOR > 0)) && ((CURSOR--)) ;;
                    '[B') ((CURSOR < COUNT - 1)) && ((CURSOR++)) ;;
                esac ;;
            ' ') [ "${CHECKED[$CURSOR]}" -eq 1 ] && CHECKED[$CURSOR]=0 || CHECKED[$CURSOR]=1 ;;
            'a') for i in "${!ELIGIBLE_AGENTS[@]}"; do CHECKED[$i]=1; done ;;
            'n') for i in "${!ELIGIBLE_AGENTS[@]}"; do CHECKED[$i]=0; done ;;
            '') break ;;
        esac
        draw_menu
    done

    SELECTED_AGENTS=()
    for i in "${!ELIGIBLE_AGENTS[@]}"; do
        [ "${CHECKED[$i]}" -eq 1 ] && SELECTED_AGENTS+=("${ELIGIBLE_AGENTS[$i]}")
    done

    if [ "${#SELECTED_AGENTS[@]}" -eq 0 ]; then
        warn "No agents selected"
        return 0
    fi

    backup_agents "$local_dir" "${SELECTED_AGENTS[@]}"
    local result
    result=$(inject_cmux_hooks "$(printf '%s\n' "${SELECTED_AGENTS[@]}")" "$local_dir")
    local updated
    updated=$(echo "$result" | awk '{print $1}')
    info "Updated $updated agents"
}

# --- Non-interactive: hook eligible agents (optionally filtered by patterns) ---
run_all() {
    local local_dir="$1"
    shift
    local patterns=("$@")

    build_eligible_agents "$local_dir"

    # Filter by patterns if provided
    if [ "${#patterns[@]}" -gt 0 ]; then
        local filtered=()
        for i in "${!ELIGIBLE_AGENTS[@]}"; do
            local bn="${ELIGIBLE_AGENTS[$i]##*/}"
            bn="${bn%.json}"
            for pat in "${patterns[@]}"; do
                # shellcheck disable=SC2254
                case "$bn" in $pat) filtered+=("${ELIGIBLE_AGENTS[$i]}"); break ;; esac
            done
        done
        ELIGIBLE_AGENTS=("${filtered[@]}")
    fi

    if [ "${#ELIGIBLE_AGENTS[@]}" -eq 0 ]; then
        if [ "${#patterns[@]}" -gt 0 ]; then
            info "No matching agents need hooking"
        else
            info "All agents already have cmux hooks"
        fi
        return 0
    fi

    backup_agents "$local_dir" "${ELIGIBLE_AGENTS[@]}"
    local result
    result=$(inject_cmux_hooks "$(printf '%s\n' "${ELIGIBLE_AGENTS[@]}")" "$local_dir")
    local updated
    updated=$(echo "$result" | awk '{print $1}')
    info "Updated $updated agents"
}

# --- Main ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    LOCAL_AGENTS_DIR=$(resolve_local_agents_dir "$PWD")
    INTERACTIVE=false
    PATTERNS=()

    for arg in "$@"; do
        case "$arg" in
            --interactive) INTERACTIVE=true ;;
            --help|-h)
                echo "Usage: hook-agents.sh [--interactive] [pattern ...]"
                echo ""
                echo "Hook eligible agents with cmux-notify.sh."
                echo ""
                echo "  (no args)        Hook all eligible agents"
                echo "  --interactive    Show checkbox picker"
                echo "  pattern          Glob pattern matched against agent name (without .json)"
                echo ""
                echo "Examples:"
                echo "  hook-agents.sh gpu-coder       # exact agent"
                echo "  hook-agents.sh 'gpu-*'         # glob prefix"
                echo "  hook-agents.sh gpu-coder builder  # multiple"
                exit 0
                ;;
            *) PATTERNS+=("$arg") ;;
        esac
    done

    if $INTERACTIVE; then
        run_interactive "$LOCAL_AGENTS_DIR"
    else
        run_all "$LOCAL_AGENTS_DIR" "${PATTERNS[@]}"
    fi
fi

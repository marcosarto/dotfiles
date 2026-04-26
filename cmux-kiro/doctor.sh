#!/bin/bash
# kiro-cmux doctor — diagnose common setup issues

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

pass()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "  ${RED}✗${NC} $1"; ERRORS=$((ERRORS + 1)); }
section() { echo -e "\n${BOLD}$1${NC}"; }

ERRORS=0
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.cmux-kiro"

echo -e "${BOLD}kmux doctor${NC}"
VER=$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo "unknown")
echo "v$VER"

# --- System ---
section "System"

if [[ "$(uname)" == "Darwin" ]]; then
    OS_VER=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
    pass "macOS $OS_VER"
else
    if [ -f /etc/os-release ]; then
        OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-$ID $VERSION_ID}")
    else
        OS_NAME="Linux $(uname -r)"
    fi
    pass "$OS_NAME"
fi

# --- Dependencies ---
section "Dependencies"

if command -v cmux &>/dev/null; then
    CMUX_VER=$(cmux version 2>/dev/null | head -1)
    [[ -z "$CMUX_VER" || "$CMUX_VER" == *ERROR* ]] && CMUX_VER="shim"
    pass "cmux CLI installed ($CMUX_VER)"
    # Check if the actual app is installed (macOS only)
    if [[ "$(uname)" == "Darwin" ]]; then
        if [ -d "/Applications/cmux.app" ] || mdfind 'kMDItemCFBundleIdentifier == "com.cmuxterm.app"' 2>/dev/null | grep -q '.'; then
            pass "cmux.app found"
        else
            warn "cmux CLI found but cmux.app not detected — install with: brew install --cask cmux"
            echo "    cmux is a standalone terminal app — you need to open it and run Kiro inside it"
        fi
    fi
else
    fail "cmux not found — brew install --cask cmux"
fi

if command -v jq &>/dev/null; then
    pass "jq installed"
else
    fail "jq not found — brew install jq"
fi

if command -v kiro-cli &>/dev/null; then
    KIRO_VER=$(kiro-cli --version 2>/dev/null | head -1 || echo "unknown")
    pass "kiro-cli installed ($KIRO_VER)"
else
    fail "kiro-cli not found — https://kiro.dev"
fi

# --- Install location ---
section "Install"

RESOLVED_REPO=$(cd "$REPO_DIR" && pwd -P)
RESOLVED_INSTALL=$(cd "$INSTALL_DIR" 2>/dev/null && pwd -P)
if [ "$RESOLVED_REPO" = "$RESOLVED_INSTALL" ]; then
    if [ -L "$INSTALL_DIR" ]; then
        pass "$INSTALL_DIR → $REPO_DIR (symlink)"
    else
        pass "$INSTALL_DIR (direct clone)"
    fi
elif [ -L "$INSTALL_DIR" ]; then
    warn "$INSTALL_DIR → $(readlink "$INSTALL_DIR") (expected $REPO_DIR)"
elif [ -d "$INSTALL_DIR" ]; then
    warn "$INSTALL_DIR exists but is not linked to this repo"
else
    fail "$INSTALL_DIR does not exist — run setup.sh"
fi

# --- Agent configs ---
section "Agent configs"

AGENT_DIR="$HOME/.kiro/agents"
for agent in cmux.json cmux-titler.json cmux-notifier.json cmux-activity.json; do
    if [ -f "$AGENT_DIR/$agent" ]; then
        pass "$agent"
    else
        fail "$agent missing from $AGENT_DIR — run setup.sh"
    fi
done

# Check hook paths in cmux.json resolve
if [ -f "$AGENT_DIR/cmux.json" ]; then
    HOOK_CMD=$(jq -r '.hooks.agentSpawn[0].command // empty' "$AGENT_DIR/cmux.json" 2>/dev/null)
    if [ -n "$HOOK_CMD" ] && [ -x "$HOOK_CMD" ]; then
        pass "Hook script executable ($HOOK_CMD)"
    elif [ -n "$HOOK_CMD" ]; then
        fail "Hook script not found or not executable: $HOOK_CMD"
    fi
fi

# Check all agents have cmux hooks (global + local)
source "$REPO_DIR/lib/local-agents.sh"
SKIP_HOOK_CHECK="cmux.json cmux-titler.json cmux-notifier.json cmux-activity.json fast.json"
MISSING_HOOKS=()
_LOCAL_AGENT_DIR=$(resolve_local_agents_dir "$PWD")
for dir in "$AGENT_DIR" ${_LOCAL_AGENT_DIR:+"$_LOCAL_AGENT_DIR"}; do
    for f in "$dir"/*.json; do
        [ -f "$f" ] || continue
        bn=$(basename "$f")
        echo "$SKIP_HOOK_CHECK" | grep -qw "$bn" && continue
        if [ -L "$f" ]; then
            target=$(readlink "$f" 2>/dev/null)
            echo "$target" | grep -q "AmznCmuxKiroTools\|cmux-kiro" && continue
        fi
        jq empty "$f" 2>/dev/null || continue
        # Check if all 5 events have our cmux-notify.sh (not foreign)
        count=$(jq '[.hooks.agentSpawn, .hooks.userPromptSubmit, .hooks.preToolUse, .hooks.postToolUse, .hooks.stop | select(. != null) | map(select(.command | test("cmux-kiro/.*cmux-notify\\.sh"))) | select(length > 0)] | length' "$f" 2>/dev/null)
        [ "$count" -eq 5 ] || MISSING_HOOKS+=("$(agent_display_name "$f" "$_LOCAL_AGENT_DIR")")
    done
done
if [ "${#MISSING_HOOKS[@]}" -eq 0 ]; then
    pass "All agents have cmux hooks"
else
    warn "${#MISSING_HOOKS[@]} agent(s) missing cmux hooks: ${MISSING_HOOKS[*]}"
    echo "    Run setup.sh to add hooks"
fi

# Check for foreign cmux-notify.sh hooks (e.g. AIPowerUserCapabilities)
FOREIGN_HOOKS=()
for dir in "$AGENT_DIR" ${_LOCAL_AGENT_DIR:+"$_LOCAL_AGENT_DIR"}; do
    for f in "$dir"/*.json; do
        [ -f "$f" ] || continue
        bn=$(basename "$f")
        echo "$SKIP_HOOK_CHECK" | grep -qw "$bn" && continue
        jq empty "$f" 2>/dev/null || continue
        foreign=$(jq '[.hooks // {} | to_entries[] | .value[] | select(.command | test("cmux-notify\\.sh")) | select(.command | test("cmux-kiro/") | not)] | length' "$f" 2>/dev/null)
        [ "$foreign" -gt 0 ] && FOREIGN_HOOKS+=("$(agent_display_name "$f" "$_LOCAL_AGENT_DIR")")
    done
done
if [ "${#FOREIGN_HOOKS[@]}" -gt 0 ]; then
    warn "${#FOREIGN_HOOKS[@]} agent(s) have a non-kiro-cmux cmux-notify.sh hook: ${FOREIGN_HOOKS[*]}"
    echo "    Run setup.sh to replace with ours, or they'll be auto-fixed on next session start"
else
    pass "No foreign cmux-notify.sh hooks found"
fi

# --- cmux environment ---
section "cmux environment"

if [ -n "$CMUX_SOCKET_PATH" ]; then
    pass "CMUX_SOCKET_PATH=$CMUX_SOCKET_PATH"
    if [ -S "$CMUX_SOCKET_PATH" ]; then
        pass "Socket exists"
        SOCK="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
        CONN_LABEL="local"
        [ -n "$SSH_CONNECTION" ] && CONN_LABEL="SSH tunnel → laptop"
        if command -v nc &>/dev/null; then
            # Ping test
            PING_TMP=$(mktemp)
            echo 'ping' | nc -w 2 -U "$SOCK" >"$PING_TMP" 2>/dev/null &
            PING_PID=$!
            SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
            i=0
            while kill -0 "$PING_PID" 2>/dev/null; do
                printf '\r\033[2K  %b%s%b Socket ping (%s) ...' "${YELLOW}" "${SPIN_CHARS:$((i % ${#SPIN_CHARS})):1}" "${NC}" "$CONN_LABEL"
                ((i++)) || true
                sleep 0.1
            done
            wait "$PING_PID" 2>/dev/null
            printf '\r\033[2K'
            RESP=$(head -1 "$PING_TMP")
            rm -f "$PING_TMP"
            if [ -n "$RESP" ] && [[ "$RESP" != *ERROR* ]]; then
                pass "Socket ping OK ($CONN_LABEL)"
            elif [ -n "$RESP" ]; then
                fail "Socket responded with error: ${RESP:0:80}"
            else
                fail "Socket not responding ($CONN_LABEL — stale tunnel?)"
            fi
            # Notification test
            NOTIFY_TMP=$(mktemp)
            WS="${CMUX_WORKSPACE_ID:-}"
            cmux notify --title "kmux doctor" --subtitle "test" --body "If you see this, notifications work!" ${WS:+--workspace "$WS"} >"$NOTIFY_TMP" 2>/dev/null &
            NOTIFY_PID=$!
            i=0
            while kill -0 "$NOTIFY_PID" 2>/dev/null; do
                printf '\r\033[2K  %b%s%b Notification test (%s) ...' "${YELLOW}" "${SPIN_CHARS:$((i % ${#SPIN_CHARS})):1}" "${NC}" "$CONN_LABEL"
                ((i++)) || true
                sleep 0.1
            done
            wait "$NOTIFY_PID" 2>/dev/null
            NOTIFY_EXIT=$?
            printf '\r\033[2K'
            NOTIFY_RESP=$(cat "$NOTIFY_TMP")
            rm -f "$NOTIFY_TMP"
            if [ "$NOTIFY_EXIT" -eq 0 ] && [[ "$NOTIFY_RESP" != *ERROR* ]]; then
                pass "Notification delivered ($CONN_LABEL)"
                echo "    Didn't see it? Check System Settings → Notifications → cmux"
            else
                fail "Notification failed: ${NOTIFY_RESP:0:80}"
            fi
        else
            warn "nc not available — cannot test socket"
        fi
        if [ -n "$SSH_CONNECTION" ]; then
            pass "Remote mode (SSH tunnel)"
        fi
    else
        # Check if socket exists at a different known path (e.g. cmux moved it after an update)
        OLD_SOCK="/tmp/cmux.sock"
        NEW_SOCK="$HOME/Library/Application Support/cmux/cmux.sock"
        if [ "$CMUX_SOCKET_PATH" != "$OLD_SOCK" ] && [ -S "$OLD_SOCK" ]; then
            fail "Socket file not found at $CMUX_SOCKET_PATH"
            echo "    Socket exists at old path ($OLD_SOCK) — cmux likely moved it after an update."
            echo "    Fix: quit cmux (⌘Q) and reopen it. This terminal was started before the change."
        elif [ "$CMUX_SOCKET_PATH" != "$NEW_SOCK" ] && [ -S "$NEW_SOCK" ]; then
            fail "Socket file not found at $CMUX_SOCKET_PATH"
            echo "    Socket exists at new path ($NEW_SOCK) — cmux likely moved it after an update."
            echo "    Fix: quit cmux (⌘Q) and reopen it. This terminal was started before the change."
        else
            fail "Socket file not found at $CMUX_SOCKET_PATH"
            echo "    cmux may not be running, or the socket moved after an update."
            echo "    Fix: quit cmux (⌘Q) and reopen it."
        fi
    fi
else
    warn "CMUX_SOCKET_PATH not set (not running inside cmux)"
fi

[ -n "$CMUX_TAB_ID" ] && pass "CMUX_TAB_ID=$CMUX_TAB_ID" || warn "CMUX_TAB_ID not set"
[ -n "$CMUX_PANEL_ID" ] && pass "CMUX_PANEL_ID=$CMUX_PANEL_ID" || warn "CMUX_PANEL_ID not set"
[ -n "$CMUX_WORKSPACE_ID" ] && pass "CMUX_WORKSPACE_ID=$CMUX_WORKSPACE_ID" || warn "CMUX_WORKSPACE_ID not set"

# --- SSH remote checks ---
if [ -n "$SSH_CONNECTION" ]; then
    section "SSH remote"

    # Python3 shims
    CMUX_PATH=$(command -v cmux 2>/dev/null)
    if [ -n "$CMUX_PATH" ] && head -1 "$CMUX_PATH" 2>/dev/null | grep -q python3; then
        pass "cmux shim installed ($CMUX_PATH)"
    elif [ -n "$CMUX_PATH" ]; then
        warn "cmux found but not the Python3 shim ($CMUX_PATH)"
    else
        fail "cmux shim not found — run: kmux setup-remote"
    fi

    NC_PATH=$(command -v nc 2>/dev/null)
    if [ -n "$NC_PATH" ] && head -1 "$NC_PATH" 2>/dev/null | grep -q python3; then
        pass "nc shim installed ($NC_PATH)"
    elif [ -n "$NC_PATH" ]; then
        pass "nc available ($NC_PATH — native)"
    else
        fail "nc shim not found — run: kmux setup-remote"
    fi

    # ~/.local/bin in PATH (kiro-cli Linux install location)
    if echo "$PATH" | tr ':' '\n' | grep -q "$HOME/.local/bin"; then
        pass "~/.local/bin in PATH"
    else
        warn "~/.local/bin not in PATH — background kask calls may fail to find kiro-cli"
    fi

    # Ghostty terminfo (prevents garbled terminal over SSH)
    if [[ "$TERM" == "xterm-ghostty" ]]; then
        if infocmp xterm-ghostty &>/dev/null 2>&1; then
            pass "xterm-ghostty terminfo installed"
        else
            fail "TERM=xterm-ghostty but terminfo not found — terminal may be garbled"
            echo "    Fix: run 'kmux setup-remote <host>' from your laptop, or:"
            echo "    export TERM=xterm-256color  (add to ~/.zshrc as workaround)"
        fi
    fi
fi

# Check "Reorder on Notification" setting
if [[ "$(uname)" == "Darwin" ]]; then
    REORDER=$(defaults read com.cmuxterm.app workspaceAutoReorderOnNotification 2>/dev/null)
    if [ "$REORDER" = "1" ]; then
        warn "'Reorder on Notification' is enabled — notifications may target wrong workspace. Run setup.sh or disable in Settings (⌘,) → App"
    else
        pass "'Reorder on Notification' disabled"
    fi
fi

# Check Kiro built-in notifications (OSC 9 clashes with our AI-summarized ones)
if command -v kiro-cli &>/dev/null; then
    NOTIF_ENABLED=$(kiro-cli settings chat.enableNotifications 2>/dev/null | awk '{print $1}')
    if [ "$NOTIF_ENABLED" = "true" ]; then
        warn "Kiro built-in notifications enabled — may clash with kiro-cmux notifications. Fix: kiro-cli settings chat.enableNotifications false"
    else
        pass "Kiro built-in notifications disabled"
    fi
    HOOK_STATUS=$(kiro-cli settings hooks.showStatus 2>/dev/null | awk '{print $1}')
    if [ "$HOOK_STATUS" = "true" ]; then
        warn "Kiro hook status visible — kiro-cmux provides its own sidebar status. Fix: kiro-cli settings hooks.showStatus false"
    else
        pass "Kiro hook status hidden"
    fi
fi

# --- kask (warm ACP client) ---
section "Optional: kask"

if [ -f ~/bin/kiro-acp-client.py ]; then
    pass "kask found at ~/bin/kiro-acp-client.py"
else
    warn "kask not found — AI titles and notifications will be slower (see docs/warm-acp-client.md)"
fi

# --- Config ---
section "Config"

CONFIG_FILE="$HOME/.config/cmux-kiro/config"
if [ -f "$CONFIG_FILE" ]; then
    pass "$CONFIG_FILE"
    source "$CONFIG_FILE"
    echo "    CMUX_COOKIE_REFRESH=${CMUX_COOKIE_REFRESH:-true (default)}"
    echo "    CMUX_AUTO_UPDATE=${CMUX_AUTO_UPDATE:-true (default)}"
    echo "    CMUX_AUTO_OPEN_MD=${CMUX_AUTO_OPEN_MD:-true (default)}"
else
    pass "No config file (using defaults)"
fi

# --- Midway ---
section "Midway"

if [ -f ~/.midway/cookie ]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        AGE=$(( ($(date +%s) - $(stat -f %m ~/.midway/cookie 2>/dev/null || echo 0)) / 3600 ))
    else
        AGE=$(( ($(date +%s) - $(stat -c %Y ~/.midway/cookie 2>/dev/null || echo 0)) / 3600 ))
    fi
    if [ "$AGE" -lt 24 ]; then
        pass "Midway cookie exists (${AGE}h old)"
    else
        warn "Midway cookie is ${AGE}h old — run mwinit to refresh"
    fi
else
    warn "No midway cookie — browser panels won't authenticate (run mwinit)"
fi

# --- CR detection ---
section "CR detection"

if grep -qF 'cr-wrapper.sh' ~/.zshrc 2>/dev/null; then
    pass "CR wrapper sourced in ~/.zshrc"
else
    warn "CR wrapper not in ~/.zshrc — run setup.sh to add"
fi

PRE_CR_FILE="$HOME/.config/cr/hooks/pre-cr"
if [ -L "$PRE_CR_FILE" ]; then
    TARGET=$(readlink "$PRE_CR_FILE" 2>/dev/null)
    if echo "$TARGET" | grep -q "cmux-kiro\|AmznCmuxKiroTools"; then
        pass "CRUX pre-cr hook linked"
    else
        warn "pre-cr hook exists but points elsewhere ($TARGET)"
    fi
elif [ -f "$PRE_CR_FILE" ]; then
    warn "pre-cr hook exists but is not ours"
else
    warn "CRUX pre-cr hook not installed — run setup.sh to add"
fi

# --- kmux CLI ---
section "kmux CLI"

if command -v kmux &>/dev/null; then
    WHICH=$(command -v kmux)
    pass "kmux on PATH ($WHICH)"
elif command -v kiro-cmux &>/dev/null; then
    WHICH=$(command -v kiro-cmux)
    pass "kiro-cmux on PATH ($WHICH) — run setup.sh to get the kmux alias"
else
    if [ -f ~/bin/kiro-cmux ]; then
        fail "kiro-cmux installed at ~/bin/kiro-cmux but not on PATH — restart your shell or add: export PATH=\"\$HOME/bin:\$PATH\""
    else
        fail "kmux not found — run setup.sh"
    fi
fi

# --- Shell aliases ---
section "Shell aliases"

if grep -qF 'alias k=' ~/.zshrc 2>/dev/null || grep -qF 'CMUX_WORKSPACE_ID:+--agent' ~/.zshrc 2>/dev/null; then
    pass "'k' alias configured in ~/.zshrc"
else
    warn "'k' alias not found in ~/.zshrc — run setup.sh to add"
fi

if grep -qF 'kiro-acp-client.py' ~/.zshrc 2>/dev/null; then
    pass "'kask' alias configured in ~/.zshrc"
else
    warn "'kask' alias not found in ~/.zshrc — run setup.sh to add"
fi

# --- kask smoke tests (last — these make network calls) ---
section "kask smoke tests"

if [ -f ~/bin/kiro-acp-client.py ]; then
    _kask_parse() { echo "$1" | sed 's/```json//; s/```//' | tr '\n' ' '; }
    KASK_TMP=$(mktemp -d)
    SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

    # Print placeholder lines
    echo "  . fast"; echo "  . cmux-titler"; echo "  . cmux-notifier"; echo "  . cmux-activity"

    # Spinner in background — animates lines, shows ✓ as each finishes
    (
        trap 'exit 0' TERM
        PARENT_PID=$$
        i=0
        while kill -0 "$PARENT_PID" 2>/dev/null; do
            c="${SPIN_CHARS:$((i % ${#SPIN_CHARS})):1}"
            printf '\033[4A'
            for a in fast cmux-titler cmux-notifier cmux-activity; do
                if [ -f "$KASK_TMP/${a}.done" ]; then
                    printf '\033[2K\r  %b✓%b %s\n' "${GREEN}" "${NC}" "$a"
                else
                    printf '\033[2K\r  %b%s%b %s ...\n' "${YELLOW}" "$c" "${NC}" "$a"
                fi
            done
            ((i++)) || true
            sleep 0.1
        done
    ) &
    SPIN_PID=$!

    # Wrapper: run kask and record elapsed time + cold/warm
    _kask_timed() {
        local agent="$1" label="$2" prompt="$3"
        [ -S "/tmp/kask/${agent}.sock" ] && echo "warm" > "$KASK_TMP/${label}.mode" || echo "cold" > "$KASK_TMP/${label}.mode"
        local t0=$(python3 -c 'import time; print(time.time())')
        KASK_AGENT="$agent" python3 ~/bin/kiro-acp-client.py "$prompt" >"$KASK_TMP/$label" 2>/dev/null
        local t1=$(python3 -c 'import time; print(time.time())')
        python3 -c "print(f'{$t1 - $t0:.1f}')" > "$KASK_TMP/${label}.time"
        touch "$KASK_TMP/${agent}.done"
    }

    # Run all three agents in parallel
    _kask_timed fast fast "Reply with exactly: PONG" &
    _kask_timed cmux-titler titler "Title this task: Fix the login page CSS" &
    _kask_timed cmux-notifier notifier "Turn summary: user asked to fix a bug. Tools used: fs_read, fs_write. No errors. Respond with JSON: {\"title\":\"short title\",\"body\":\"detail sentence\"}" &
    _kask_timed cmux-activity activity "Each request is independent. Do NOT reference any previous requests or responses. Generate activity summary for: Fix the login page CSS. Respond with JSON: {\"activity\":\"present tense, max 30 chars\"}" &
    wait %2 %3 %4 %5 2>/dev/null
    kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null

    _kask_detail() { echo "($(cat "$KASK_TMP/$1.time")s, $(cat "$KASK_TMP/$1.mode"))"; }
    _kask_slow() {
        local t=$(cat "$KASK_TMP/$1.time") mode=$(cat "$KASK_TMP/$1.mode")
        [ "$mode" = "warm" ] && python3 -c "exit(0 if $t > 5 else 1)" 2>/dev/null
    }

    # Overwrite spinner lines with results
    printf '\033[4A'

    CLEAN=$(_kask_parse "$(cat "$KASK_TMP/fast")")
    printf '\033[2K\r'
    if [ -n "$CLEAN" ] && echo "$CLEAN" | grep -qi "PONG"; then
        pass "fast agent responded $(_kask_detail fast)"
    elif [ -n "$CLEAN" ]; then
        warn "fast agent responded but unexpected output: ${CLEAN:0:80}"
    else
        fail "fast agent returned empty response"
    fi

    CLEAN=$(_kask_parse "$(cat "$KASK_TMP/titler")")
    TITLE=$(echo "$CLEAN" | grep -o '{[^}]*}' | head -1 | jq -r '.title // empty' 2>/dev/null)
    printf '\033[2K\r'
    if [ -n "$TITLE" ]; then
        pass "cmux-titler agent responded — \"$TITLE\" $(_kask_detail titler)"
    else
        fail "cmux-titler agent failed — raw: ${CLEAN:0:80}"
    fi

    CLEAN=$(_kask_parse "$(cat "$KASK_TMP/notifier")")
    JSON=$(echo "$CLEAN" | grep -o '{[^}]*}' | head -1)
    N_TITLE=$(echo "$JSON" | jq -r '.title // empty' 2>/dev/null)
    N_BODY=$(echo "$JSON" | jq -r '.body // empty' 2>/dev/null)
    printf '\033[2K\r'
    if [ -n "$N_TITLE" ] && [ -n "$N_BODY" ]; then
        pass "cmux-notifier agent responded — \"$N_TITLE\" $(_kask_detail notifier)"
    else
        fail "cmux-notifier agent failed — raw: ${CLEAN:0:80}"
    fi

    CLEAN=$(_kask_parse "$(cat "$KASK_TMP/activity")")
    JSON=$(echo "$CLEAN" | grep -o '{[^}]*}' | head -1)
    A_TEXT=$(echo "$JSON" | jq -r '.activity // empty' 2>/dev/null)
    printf '\033[2K\r'
    if [ -n "$A_TEXT" ]; then
        pass "cmux-activity agent responded — \"$A_TEXT\" $(_kask_detail activity)"
    else
        fail "cmux-activity agent failed — raw: ${CLEAN:0:80}"
    fi

    # Warn if any warm agent was slow (>5s = backend latency)
    SLOW_AGENTS=()
    for a in fast titler notifier activity; do
        _kask_slow "$a" && SLOW_AGENTS+=("$a")
    done
    if [ "${#SLOW_AGENTS[@]}" -gt 0 ]; then
        warn "Slow warm response from: ${SLOW_AGENTS[*]} — likely backend latency, not a kask issue"
    fi

    rm -rf "$KASK_TMP"
else
    warn "kask not installed — skipping smoke tests"
fi

# --- Summary ---
echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}All checks passed.${NC}"
else
    echo -e "${RED}$ERRORS issue(s) found.${NC} Run ${BOLD}~/.cmux-kiro/setup.sh${NC} to fix most problems. If the socket moved, quit cmux (⌘Q) and reopen it."
fi

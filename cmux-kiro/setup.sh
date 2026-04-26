#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }
step()  { echo -e "\n${BOLD}$1${NC}"; }
confirm() {
    local default="${2:-y}"
    local hint="Y/n" && [[ "$default" == "n" ]] && hint="y/N"
    while true; do
        read -r -p "$1 [$hint] " reply
        [[ -z "$reply" ]] && reply="$default"
        case "$reply" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *)    echo "  Please enter Y or N" ;;
        esac
    done
}

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.cmux-kiro"

WEBHOOK_URL="https://hooks.slack.com/triggers/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"
_ping() { curl -s -X POST "$WEBHOOK_URL" -H 'Content-Type: application/json' -d "{\"alias\":\"$(whoami)\",\"version\":\"$(cat "$REPO_DIR/VERSION" 2>/dev/null)\",\"event\":\"install\",\"status\":\"${1}\",\"sessions\":0,\"notifications\":0}" >/dev/null 2>&1 & }
_setup_step="init"
trap '_ping "error:${_setup_step}"' ERR

# --- Helper: check if agent has any cmux hooks (for --remove-hooks) ---
has_any_cmux_hooks() {
    local f="$1"
    local count=$(jq '[.hooks.agentSpawn, .hooks.userPromptSubmit, .hooks.preToolUse, .hooks.postToolUse, .hooks.stop | select(. != null) | map(select(.command | contains("cmux-notify.sh"))) | select(length > 0)] | length' "$f" 2>/dev/null)
    [ "$count" -gt 0 ]
}

# --- Helper: resolve local agents dir ---
source "$REPO_DIR/lib/local-agents.sh"

# Wrappers using shared lib (setup.sh uses $PWD)
_local_agents_dir() { resolve_local_agents_dir "$PWD"; }
_agent_display_name() { agent_display_name "$@"; }

# --- --remove-hooks mode ---
if [ "$1" = "--remove-hooks" ]; then
    echo -e "${BOLD}kmux — remove hooks${NC}"
    echo ""

    GLOBAL_DIR="$HOME/.kiro/agents"
    LOCAL_DIR=$(_local_agents_dir)
    SKIP_AGENTS="cmux.json cmux-titler.json cmux-notifier.json fast.json"
    # HOOKED stores full paths; HOOKED_DISPLAY stores picker labels
    HOOKED=()
    HOOKED_DISPLAY=()
    for dir in "$GLOBAL_DIR" ${LOCAL_DIR:+"$LOCAL_DIR"}; do
        for f in "$dir"/*.json; do
            [ -f "$f" ] || continue
            bn=$(basename "$f")
            echo "$SKIP_AGENTS" | grep -qw "$bn" && continue
            jq empty "$f" 2>/dev/null || continue
            has_any_cmux_hooks "$f" || continue
            HOOKED+=("$f")
            HOOKED_DISPLAY+=("$(_agent_display_name "$f" "$LOCAL_DIR")")
        done
    done

    if [ "${#HOOKED[@]}" -eq 0 ]; then
        info "No agents have cmux hooks"
        exit 0
    fi

    # Checkbox picker — all checked by default
    CHECKED=()
    for i in "${!HOOKED[@]}"; do CHECKED[$i]=1; done
    CURSOR=0
    COUNT=${#HOOKED[@]}

    draw_menu() {
        if [ "${DRAWN:-0}" -eq 1 ]; then
            printf '\033[%dA' "$((COUNT + 1))"
        fi
        for i in "${!HOOKED[@]}"; do
            local marker="[ ]"
            [ "${CHECKED[$i]}" -eq 1 ] && marker="[x]"
            local prefix="  "
            [ "$i" -eq "$CURSOR" ] && prefix="▸ "
            printf '\033[2K%s%s %s\n' "$prefix" "$marker" "${HOOKED_DISPLAY[$i]}"
        done
        printf '\033[2K  ↑↓ move · space toggle · a all · n none · enter confirm\n'
        DRAWN=1
    }

    echo "  Select agents to remove cmux hooks from:"
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
            'a') for i in "${!HOOKED[@]}"; do CHECKED[$i]=1; done ;;
            'n') for i in "${!HOOKED[@]}"; do CHECKED[$i]=0; done ;;
            '') break ;;
        esac
        draw_menu
    done

    SELECTED=()
    for i in "${!HOOKED[@]}"; do
        [ "${CHECKED[$i]}" -eq 1 ] && SELECTED+=("${HOOKED[$i]}")
    done

    if [ "${#SELECTED[@]}" -eq 0 ]; then
        warn "No agents selected"
        exit 0
    fi

    # Backup global agents (only if any selected are global)
    for f in "${SELECTED[@]}"; do
        if [ -z "$LOCAL_DIR" ] || [[ "$f" != "$LOCAL_DIR"/* ]]; then
            if [ -d "$GLOBAL_DIR" ]; then
                BACKUP_DIR="$HOME/.kiro/agents.backup.$(date +%Y%m%d%H%M%S)"
                if ! cp -r "$GLOBAL_DIR/" "$BACKUP_DIR"; then
                    warn "Failed to create global backup — aborting"
                    exit 1
                fi
                info "Backup created at $BACKUP_DIR"
            fi
            break
        fi
    done
    # Backup local agents (only if any selected are local)
    if [ -n "$LOCAL_DIR" ]; then
        for f in "${SELECTED[@]}"; do
            if [[ "$f" == "$LOCAL_DIR"/* ]]; then
                LOCAL_BACKUP="$PWD/.kiro/agents.backup.$(date +%Y%m%d%H%M%S)"
                if ! cp -r "$LOCAL_DIR/" "$LOCAL_BACKUP"; then
                    warn "Failed to create local backup — aborting"
                    exit 1
                fi
                info "Local backup at $LOCAL_BACKUP"
                break
            fi
        done
    fi

    # Remove cmux hooks from selected agents
    REMOVED=0
    EVENTS="agentSpawn userPromptSubmit preToolUse postToolUse stop"
    for f in "${SELECTED[@]}"; do
        [ -f "$f" ] || continue
        jq_filter='.'
        for evt in $EVENTS; do
            jq_filter+=" | if .hooks.${evt} then .hooks.${evt} = [.hooks.${evt}[] | select(.command | contains(\"cmux-notify.sh\") | not)] else . end"
            jq_filter+=" | if .hooks.${evt} == [] then del(.hooks.${evt}) else . end"
        done
        jq_filter+=' | if .hooks == {} then del(.hooks) else . end'
        result=$(jq "$jq_filter" "$f" 2>/dev/null) && echo "$result" > "$f" && ((REMOVED++)) || true
    done

    info "Removed cmux hooks from $REMOVED agents"

    # Remove CR wrapper from .zshrc
    if grep -qF 'cr-wrapper.sh' ~/.zshrc 2>/dev/null; then
        sed -i '' '/# kiro-cmux: detect CRs created outside Kiro/d; /cr-wrapper\.sh/d' ~/.zshrc
        info "Removed CR wrapper from ~/.zshrc"
    fi

    # Remove pre-cr symlink if it's ours
    PRE_CR_FILE="$HOME/.config/cr/hooks/pre-cr"
    if [ -L "$PRE_CR_FILE" ]; then
        TARGET=$(readlink "$PRE_CR_FILE" 2>/dev/null)
        if echo "$TARGET" | grep -q "cmux-kiro\|AmznCmuxKiroTools"; then
            rm -f "$PRE_CR_FILE"
            info "Removed CRUX pre-cr hook"
        fi
    fi

    exit 0
fi

echo -e "${BOLD}kmux setup${NC}"
echo "First-class Kiro CLI integration for cmux"
echo ""

# 0. Ensure ~/.cmux-kiro points to this repo
_setup_step="install_location"
step "Checking install location..."
if [ "$REPO_DIR" = "$INSTALL_DIR" ] || [ "$(readlink "$INSTALL_DIR" 2>/dev/null)" = "$REPO_DIR" ]; then
    info "Install location OK ($INSTALL_DIR)"
elif [ -L "$INSTALL_DIR" ]; then
    warn "Updating $INSTALL_DIR symlink"
    ln -sfn "$REPO_DIR" "$INSTALL_DIR"
    info "Linked $INSTALL_DIR → repo"
elif [ -d "$INSTALL_DIR" ]; then
    warn "$INSTALL_DIR already exists as a directory"
    echo "  If you want to use this repo instead, remove it first:"
    echo "  rm -rf $INSTALL_DIR && ln -s $REPO_DIR $INSTALL_DIR"
else
    ln -sfn "$REPO_DIR" "$INSTALL_DIR"
    info "Linked $INSTALL_DIR → $REPO_DIR"
fi

# 1. Check cmux
_setup_step="check_cmux"
step "Checking cmux..."
# Detect non-brew cmux and offer to replace with brew version
if [[ "$(uname)" == "Darwin" ]] && [ -d "/Applications/cmux.app" ] && ! brew list --cask cmux &>/dev/null; then
    warn "cmux is installed outside Homebrew (manual/DMG install)"
    echo "  Homebrew is recommended for automatic updates."
    if confirm "Uninstall manual cmux and reinstall via Homebrew?"; then
        echo "  Quitting cmux..."
        osascript -e 'quit app "cmux"' 2>/dev/null || true
        sleep 1
        echo "  Removing /Applications/cmux.app..."
        rm -rf /Applications/cmux.app
        echo "  Running: brew install --cask cmux"
        if brew install --cask cmux; then
            info "cmux reinstalled via Homebrew"
        else
            error "brew install failed — install manually from https://cmux.dev"
        fi
    fi
fi
if command -v cmux &>/dev/null; then
    VERSION=$(cmux version 2>/dev/null || echo "unknown")
    info "cmux found ($VERSION)"
elif [[ "$(uname)" != "Darwin" ]]; then
    warn "cmux is macOS-only — skipping (hooks will be inactive on this host)"
else
    warn "cmux is not installed"
    echo "  cmux is a standalone macOS terminal app — you'll run Kiro inside it."
    if confirm "Install cmux via Homebrew?"; then
        echo "Running: brew install --cask cmux"
        if brew install --cask cmux; then
            info "cmux installed — open cmux.app from Applications to get started"
        else
            error "brew install failed — install manually from https://cmux.dev"
        fi
    else
        warn "Skipped — install manually from https://cmux.dev"
    fi
fi

# 2. Check jq
_setup_step="check_jq"
step "Checking jq..."
if command -v jq &>/dev/null; then
    info "jq found"
else
    warn "jq is not installed"
    if confirm "Install jq via Homebrew?"; then
        if brew install jq; then
            info "jq installed"
        else
            error "brew install failed — install jq manually"
        fi
    else
        warn "Skipped — install jq manually (brew install jq)"
    fi
fi

# 3. Check kiro-cli
_setup_step="check_kiro_cli"
step "Checking kiro-cli..."
if command -v kiro-cli &>/dev/null; then
    info "kiro-cli found"
else
    warn "kiro-cli not found — install from https://kiro.dev"
fi

# 4. Generate agent configs
_setup_step="agent_configs"
step "Setting up agent configs..."
mkdir -p ~/.kiro/agents

# Generate cmux.json from template with paths expanded
if [ -f "$REPO_DIR/agents/cmux.json.template" ]; then
    sed "s|__INSTALL_DIR__|$INSTALL_DIR|g; s|__HOME__|$HOME|g" \
        "$REPO_DIR/agents/cmux.json.template" > ~/.kiro/agents/cmux.json
    info "Generated cmux.json → ~/.kiro/agents/"
else
    warn "Missing cmux.json.template — falling back to symlink"
    ln -sf "$REPO_DIR/agents/cmux.json" ~/.kiro/agents/cmux.json
fi

# Symlink other agent configs (these don't have path-dependent content)
for agent in cmux-titler.json cmux-notifier.json cmux-activity.json; do
    if [ -f "$REPO_DIR/agents/$agent" ]; then
        ln -sf "$REPO_DIR/agents/$agent" ~/.kiro/agents/"$agent"
        info "Linked $agent → ~/.kiro/agents/"
    else
        warn "Missing $agent in repo"
    fi
done

# Install user-facing steering file
mkdir -p ~/.kiro/steering
if [ -f "$REPO_DIR/steering/cmux-kiro-usage.md" ]; then
    ln -sf "$REPO_DIR/steering/cmux-kiro-usage.md" ~/.kiro/steering/cmux-kiro-usage.md
    # Remove old dev steering file if it's a symlink
    [ -L ~/.kiro/steering/cmux-kiro-integration.md ] && \
        rm -f ~/.kiro/steering/cmux-kiro-integration.md
    info "Linked cmux-kiro-usage.md → ~/.kiro/steering/"
fi

# 5. Inject cmux hooks into all other agents
_setup_step="inject_hooks"
step "Injecting cmux hooks into agents..."
if ! CMUX_KIRO_INSTALL_DIR="$INSTALL_DIR" "$REPO_DIR/lib/hook-agents.sh" --interactive; then
    warn "Hook injection failed"
    exit 1
fi

# 6. Create default config
_setup_step="config"
step "Checking config..."
CONFIG_DIR="$HOME/.config/cmux-kiro"
CONFIG_FILE="$CONFIG_DIR/config"
if [ -f "$CONFIG_FILE" ]; then
    info "Config exists at $CONFIG_FILE"
else
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<'EOF'
# cmux-kiro configuration
# Background cookie refresh daemon (re-auths browser panels after mwinit)
CMUX_COOKIE_REFRESH=true
# Auto-update on session start (checks once per day)
CMUX_AUTO_UPDATE=true
# Show raw tool names instead of human-readable descriptions (e.g. "fs_read" vs "Reading config.ts")
# CMUX_RAW_TOOL_NAMES=false
# Auto-open markdown files as sidebar panels when Kiro writes .md files
CMUX_AUTO_OPEN_MD=true
EOF
    info "Created default config at $CONFIG_FILE"
fi

# 7. Install kask (warm ACP client)
_setup_step="kask"
step "Setting up kask..."
if ! command -v python3 &>/dev/null; then
    warn "python3 not found — kask requires it. Install Xcode CLT (xcode-select --install) or Homebrew python"
fi
mkdir -p ~/bin
# Dev mode: ~/.cmux-kiro is a symlink → use symlinks so edits propagate instantly
DEV_MODE=false
[ -L "$INSTALL_DIR" ] && DEV_MODE=true
_install_bin() {
    if $DEV_MODE; then
        ln -sf "$1" "$2"
    else
        cp "$1" "$2"
        chmod +x "$2"
    fi
}
if [ -f "$REPO_DIR/bin/kiro-acp-client.py" ]; then
    _install_bin "$REPO_DIR/bin/kiro-acp-client.py" ~/bin/kiro-acp-client.py
    info "Installed kiro-acp-client.py → ~/bin/$($DEV_MODE && echo ' (symlink)')"
else
    warn "bin/kiro-acp-client.py missing from repo"
fi
if [ -f "$REPO_DIR/bin/kiro-cmux" ]; then
    _install_bin "$REPO_DIR/bin/kiro-cmux" ~/bin/kiro-cmux
    # kmux is the short alias — symlink to the same script
    ln -sf ~/bin/kiro-cmux ~/bin/kmux
    info "Installed kiro-cmux (+ kmux alias) → ~/bin/$($DEV_MODE && echo ' (symlink)')"
    # Symlink into /usr/local/bin so it's on PATH immediately (no shell restart needed)
    ln -sf ~/bin/kiro-cmux /usr/local/bin/kiro-cmux 2>/dev/null || true
    ln -sf ~/bin/kiro-cmux /usr/local/bin/kmux 2>/dev/null || true
else
    warn "bin/kiro-cmux missing from repo"
fi

# Ensure ~/bin is in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/bin"; then
    PATH_LINE='export PATH="$HOME/bin:$PATH"'
    if grep -qF 'HOME/bin' ~/.zshrc 2>/dev/null; then
        info "~/bin PATH entry already in ~/.zshrc (restart your shell to pick it up)"
    else
        if confirm "Add ~/bin to your PATH in ~/.zshrc? (needed for kmux CLI)"; then
            echo "" >> ~/.zshrc
            echo "# kiro-cmux: add ~/bin to PATH" >> ~/.zshrc
            echo "$PATH_LINE" >> ~/.zshrc
            info "Added ~/bin to PATH in ~/.zshrc (restart your shell or run: source ~/.zshrc)"
        else
            warn "Skipped — add manually: $PATH_LINE"
        fi
    fi
fi

# Symlink fast.json agent (used by kask)
if [ -f "$REPO_DIR/agents/fast.json" ]; then
    ln -sf "$REPO_DIR/agents/fast.json" ~/.kiro/agents/fast.json
    info "Linked fast.json → ~/.kiro/agents/"
fi

# 8. CR detection (shell wrapper + CRUX pre-cr hook)
_setup_step="cr_detection"
step "Setting up CR detection..."

# 8a. Source cr-wrapper.sh in .zshrc
CR_SOURCE_LINE="source $INSTALL_DIR/lib/cr-wrapper.sh"
if grep -qF 'cr-wrapper.sh' ~/.zshrc 2>/dev/null; then
    info "CR wrapper already sourced in ~/.zshrc"
else
    # Check for existing cr alias that would conflict with our function definition
    existing_cr_alias=$(grep -E '^\s*alias\s+cr=' ~/.zshrc 2>/dev/null | tail -1) || true
    if [ -n "$existing_cr_alias" ]; then
        warn "You have an existing cr alias in ~/.zshrc:"
        echo "  $existing_cr_alias"
        echo "  Our CR wrapper defines a cr() function that calls \`command cr\` and pins CRs to the sidebar."
        echo "  The alias must be removed for the wrapper to work (zsh can't define a function over an alias)."
        if confirm "Replace your cr alias with the cmux CR wrapper?"; then
            sed -i '' '/^\s*alias\s\{1,\}cr=/d' ~/.zshrc
            echo "" >> ~/.zshrc
            echo "# kiro-cmux: detect CRs created outside Kiro" >> ~/.zshrc
            echo "$CR_SOURCE_LINE" >> ~/.zshrc
            info "Replaced cr alias with CR wrapper in ~/.zshrc"
        else
            warn "Skipped — CR detection won't work with the existing alias"
        fi
    elif confirm "Add CR detection to your shell? (pins CRs to sidebar from any pane)"; then
        echo "" >> ~/.zshrc
        echo "# kiro-cmux: detect CRs created outside Kiro" >> ~/.zshrc
        echo "$CR_SOURCE_LINE" >> ~/.zshrc
        info "Added CR wrapper to ~/.zshrc"
    else
        warn "Skipped — you can add it manually:"
        echo "  $CR_SOURCE_LINE"
    fi
fi

# 8b. CRUX pre-cr hook
PRE_CR_DIR="$HOME/.config/cr/hooks"
PRE_CR_FILE="$PRE_CR_DIR/pre-cr"
if [ -L "$PRE_CR_FILE" ]; then
    TARGET=$(readlink "$PRE_CR_FILE" 2>/dev/null)
    if echo "$TARGET" | grep -q "cmux-kiro\|AmznCmuxKiroTools"; then
        info "CRUX pre-cr hook already linked"
    else
        warn "pre-cr hook exists but points elsewhere ($TARGET) — skipping"
    fi
elif [ -f "$PRE_CR_FILE" ]; then
    warn "pre-cr hook already exists (not ours) — skipping"
    echo "  To chain ours, add to your $PRE_CR_FILE:"
    echo "    $INSTALL_DIR/hooks/pre-cr \"\$@\""
else
    mkdir -p "$PRE_CR_DIR"
    ln -sf "$INSTALL_DIR/hooks/pre-cr" "$PRE_CR_FILE"
    info "Linked CRUX pre-cr hook"
fi

# 9. Shell aliases
_setup_step="shell_aliases"
step "Checking shell aliases..."
ALIAS_LINE='alias k="kiro-cli chat -a --agent cmux"'
KASK_ALIAS='alias kask="python3 ~/bin/kiro-acp-client.py"'

if grep -q 'alias k=.*--agent cmux' ~/.zshrc 2>/dev/null || grep -qF 'CMUX_WORKSPACE_ID:+--agent' ~/.zshrc 2>/dev/null; then
    info "'k' alias already configured in ~/.zshrc"
elif grep -qF 'alias k=' ~/.zshrc 2>/dev/null; then
    warn "'k' alias exists but doesn't use --agent cmux"
    if confirm "Update 'k' alias to use the cmux agent?"; then
        sed -i '' 's|^alias k=.*|'"$ALIAS_LINE"'|' ~/.zshrc
        info "Updated 'k' alias in ~/.zshrc"
    else
        warn "Skipped — you can update it manually:"
        echo "  $ALIAS_LINE"
    fi
else
    if confirm "Add 'k' alias to ~/.zshrc? (shorthand for the cmux agent)"; then
        echo "" >> ~/.zshrc
        echo "# kiro-cmux: shorthand for the cmux agent" >> ~/.zshrc
        echo "$ALIAS_LINE" >> ~/.zshrc
        info "Added 'k' alias to ~/.zshrc"
    else
        warn "Skipped — you can add it manually:"
        echo "  $ALIAS_LINE"
    fi
fi

if grep -qF 'kiro-acp-client.py' ~/.zshrc 2>/dev/null; then
    info "'kask' alias already configured in ~/.zshrc"
else
    if confirm "Add 'kask' alias to ~/.zshrc? (warm ACP client for fast prompts)"; then
        echo "" >> ~/.zshrc
        echo "# kask: warm kiro ACP client" >> ~/.zshrc
        echo "$KASK_ALIAS" >> ~/.zshrc
        info "Added 'kask' alias to ~/.zshrc"
    else
        warn "Skipped — you can add it manually:"
        echo "  $KASK_ALIAS"
    fi
fi

KOPEN_ALIAS='alias kopen="kmux open"'
if grep -qF 'alias kopen' ~/.zshrc 2>/dev/null; then
    info "'kopen' alias already configured in ~/.zshrc"
else
    if confirm "Add 'kopen' alias to ~/.zshrc? (shorthand for kmux open)"; then
        echo "" >> ~/.zshrc
        echo "# kiro-cmux: open internal sites in cmux browser with auth" >> ~/.zshrc
        echo "$KOPEN_ALIAS" >> ~/.zshrc
        info "Added 'kopen' alias to ~/.zshrc"
    else
        warn "Skipped — you can add it manually:"
        echo "  $KOPEN_ALIAS"
    fi
fi

# 10. cmux preferences (macOS only)
if [[ "$(uname)" == "Darwin" ]]; then
    _setup_step="cmux_prefs"
    step "Checking cmux settings..."

    # Dark mode — pill colors are designed for dark backgrounds
    if [ "$(defaults read com.cmuxterm.app appearanceMode 2>/dev/null)" != "dark" ]; then
        defaults write com.cmuxterm.app appearanceMode -string dark
        info "Enabled dark mode — sidebar pill colors are optimized for dark backgrounds"
    else
        info "Dark mode already enabled"
    fi

    # Disable "Reorder on Notification" (notifications target wrong workspace when enabled)
    if defaults read com.cmuxterm.app workspaceAutoReorderOnNotification 2>/dev/null | grep -q 1; then
        defaults write com.cmuxterm.app workspaceAutoReorderOnNotification -bool false
        info "Disabled 'Reorder on Notification' — prevents notifications targeting wrong workspace"
    else
        info "'Reorder on Notification' already disabled"
    fi

    # Socket control — need at least "automation" for hooks and external commands to work
    _sock_mode=$(defaults read com.cmuxterm.app socketControlMode 2>/dev/null || echo "")
    if [ "$_sock_mode" = "off" ] || [ "$_sock_mode" = "cmuxOnly" ] || [ -z "$_sock_mode" ]; then
        defaults write com.cmuxterm.app socketControlMode -string automation 2>/dev/null || true
        info "Enabled socket automation mode — required for sidebar integration"
    elif [ "$_sock_mode" = "automation" ] || [ "$_sock_mode" = "allowAll" ]; then
        info "Socket control already enabled ($_sock_mode)"
    fi
fi

# 11. Disable Kiro's built-in terminal notifications (we provide better AI-summarized ones)
if command -v kiro-cli &>/dev/null; then
    kiro-cli settings chat.enableNotifications false 2>/dev/null || true
    kiro-cli settings hooks.showStatus false 2>/dev/null || true
    info "Disabled Kiro built-in notifications and hook status (kiro-cmux provides its own)"
fi

# 12. Summary
VER=$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo "unknown")

_ping "ok"

step "Setup complete! (v$VER)"
echo ""
echo "cmux hooks are active on all your agents — just use Kiro as normal."

# Interactive onboarding tour — first install only, with a tty
ONBOARDING_MARKER="$HOME/.config/cmux-kiro/.onboarded"
SOCKET="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
if [ ! -f "$ONBOARDING_MARKER" ] && [ -t 0 ]; then
    echo ""
    echo -e "  ${BOLD}🎉 Want a quick tour?${NC}"
    echo -e "  See the sidebar, notifications, and live status in action (~1 min)."
    echo ""
    _tour_launched=false
    if [ -S "$SOCKET" ] && [ -n "$CMUX_TAB_ID$CMUX_WORKSPACE_ID" ]; then
        # Already inside cmux
        if confirm "  Launch the interactive tour?"; then
            _tour_ws=$(cmux new-workspace --name "✨ Welcome" --command "kmux tour; exec ${SHELL:-zsh}" 2>/dev/null | grep -o 'workspace:[0-9]*')
            if [ -n "$_tour_ws" ]; then
                cmux select-workspace --workspace "$_tour_ws" >/dev/null 2>&1 || true
                info "Tour launched — switch to the ✨ Welcome tab ←"
                _tour_launched=true
            else
                warn "Could not launch tour workspace — run ${BOLD}kmux tour${NC} manually"
            fi
        fi
    elif [[ "$(uname)" == "Darwin" ]] && [ -d "/Applications/cmux.app" ]; then
        # Not inside cmux — open it for them
        if confirm "  Launch the interactive tour? (opens cmux)"; then
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
                    CMUX_SOCKET_PATH="$_tour_sock" cmux select-workspace --workspace "$_tour_ws" >/dev/null 2>&1 || true
                    info "Tour launched in cmux (if it didn't appear, run ${BOLD}kmux tour${NC} inside cmux)"
                    _tour_launched=true
                else
                    warn "cmux socket access denied — run ${BOLD}kmux tour${NC} inside a cmux terminal"
                fi
            else
                info "cmux opened — run ${BOLD}kmux tour${NC} in a cmux terminal"
            fi
        fi
    fi
    mkdir -p "$(dirname "$ONBOARDING_MARKER")" && touch "$ONBOARDING_MARKER"
fi

if [ "${_tour_launched:-false}" = "true" ]; then
    echo -e "The tour covers everything you need to get started. Enjoy! 🚀"
elif [ "${_first_install:-false}" = "true" ]; then
    if [ ! -S "$SOCKET" ] || [ -z "$CMUX_TAB_ID$CMUX_WORKSPACE_ID" ]; then
        echo -e "${BOLD}Next step: open cmux.app and run Kiro inside it.${NC}"
        echo "cmux is a standalone terminal app — the sidebar, notifications, and browser"
        echo "panels only work when Kiro runs inside a cmux workspace."
        echo ""
    fi
    echo "Make sure cmux is running with automation enabled:"
    echo "  cmux Settings (⌘,) → Socket Control → Automation mode"
    echo ""
    echo "For desktop notifications when Kiro finishes a task:"
    echo "  System Settings → Notifications → cmux → Allow Notifications"
fi
echo ""
echo -e "To remove hooks later: ${BOLD}kmux setup --remove-hooks${NC}"
echo -e "To update:             ${BOLD}kmux update${NC}"
echo -e "Feature tour:          ${BOLD}kmux tour${NC}"
echo -e "Feedback:              ${BOLD}#cmux-interest${NC} on Slack"

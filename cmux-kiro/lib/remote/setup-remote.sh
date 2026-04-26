#!/usr/bin/env bash
# setup-remote.sh — Set up kiro-cmux on a remote Linux host (no cmux binary needed).
# Installs python3 shims for cmux/nc, injects hooks into agents, links agent configs.
# Run ON the remote machine after cloning the repo to ~/.cmux-kiro.
set -euo pipefail

BOLD='\033[1m' NC='\033[0m' GREEN='\033[0;32m' YELLOW='\033[0;33m' RED='\033[0;31m'
step()  { echo -e "\n${BOLD}▸ $1${NC}"; }
info()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
err()   { echo -e "  ${RED}✗${NC} $1"; }

REPO_DIR="${HOME}/.cmux-kiro"
INSTALL_DIR="$REPO_DIR"
BIN_DIR="${HOME}/bin"

echo -e "${BOLD}kiro-cmux remote setup${NC}"
echo "Sets up cmux integration for Kiro running over SSH."
echo ""

# --- Preflight ---
step "Checking prerequisites..."

if [[ ! -d "$REPO_DIR" ]]; then
    err "~/.cmux-kiro not found. Clone first:"
    echo "  git clone ssh://git.amazon.com/pkg/AmznCmuxKiroTools ~/.cmux-kiro"
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    err "python3 not found — required for shims"
    exit 1
fi
info "python3 found"

if ! command -v jq &>/dev/null; then
    warn "jq not found — needed for hook injection. Install: sudo yum install -y jq"
    JQ_OK=false
else
    info "jq found"
    JQ_OK=true
fi

if ! command -v kiro-cli &>/dev/null; then
    warn "kiro-cli not found — install from https://kiro.dev"
else
    info "kiro-cli found"
fi

# --- Install shims ---
step "Installing cmux & nc shims..."

SHIM_DIR="$REPO_DIR/lib/remote"
if [[ ! -f "$SHIM_DIR/cmux-shim" ]] || [[ ! -f "$SHIM_DIR/nc-shim" ]]; then
    err "Shims missing in $SHIM_DIR — update the repo: cd ~/.cmux-kiro && git pull"
    exit 1
fi

mkdir -p "$BIN_DIR"
cp "$SHIM_DIR/cmux-shim" "$BIN_DIR/cmux"
cp "$SHIM_DIR/nc-shim" "$BIN_DIR/nc"
chmod +x "$BIN_DIR/cmux" "$BIN_DIR/nc"
info "Installed cmux shim → $BIN_DIR/cmux"
info "Installed nc shim   → $BIN_DIR/nc"

# --- Ensure ~/bin in PATH ---
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/bin"; then
    PATH_LINE='export PATH="$HOME/bin:$PATH"'
    if grep -qF 'HOME/bin' ~/.zshrc 2>/dev/null || grep -qF 'HOME/bin' ~/.bashrc 2>/dev/null; then
        info "~/bin PATH entry already in shell rc (restart shell to pick it up)"
    else
        SHELL_RC="$HOME/.zshrc"
        [[ -f "$SHELL_RC" ]] || SHELL_RC="$HOME/.bashrc"
        read -p "  Add ~/bin to PATH in $(basename "$SHELL_RC")? [Y/n] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo "" >> "$SHELL_RC"
            echo "# kiro-cmux: add ~/bin to PATH" >> "$SHELL_RC"
            echo "$PATH_LINE" >> "$SHELL_RC"
            info "Added ~/bin to PATH in $(basename "$SHELL_RC")"
            export PATH="$HOME/bin:$PATH"
        fi
    fi
fi

# --- Install ghostty terminfo ---
step "Checking terminal info..."
if infocmp xterm-ghostty &>/dev/null 2>&1; then
    info "xterm-ghostty terminfo already installed"
else
    warn "xterm-ghostty terminfo not found — 'clear' etc. may show 'unknown terminal type'"
    echo "  Fix: run this from your laptop (inside cmux):"
    echo "    infocmp -x xterm-ghostty | ssh $(hostname -s) tic -x -"
    echo "  Or use: kmux setup-remote $(hostname -s)  (installs it automatically)"
fi

# --- Agent configs ---
step "Setting up agent configs..."
mkdir -p ~/.kiro/agents

# Generate cmux.json from template
if [ -f "$REPO_DIR/agents/cmux.json.template" ]; then
    sed "s|__INSTALL_DIR__|$INSTALL_DIR|g; s|__HOME__|$HOME|g" \
        "$REPO_DIR/agents/cmux.json.template" > ~/.kiro/agents/cmux.json
    info "Generated cmux.json → ~/.kiro/agents/"
fi

# Symlink supporting agents
for agent in cmux-titler.json cmux-notifier.json cmux-activity.json fast.json; do
    if [ -f "$REPO_DIR/agents/$agent" ]; then
        ln -sf "$REPO_DIR/agents/$agent" ~/.kiro/agents/"$agent"
        info "Linked $agent → ~/.kiro/agents/"
    fi
done

# Install steering file
mkdir -p ~/.kiro/steering
if [ -f "$REPO_DIR/steering/cmux-kiro-usage.md" ]; then
    ln -sf "$REPO_DIR/steering/cmux-kiro-usage.md" ~/.kiro/steering/cmux-kiro-usage.md
    info "Linked cmux-kiro-usage.md → ~/.kiro/steering/"
fi

# --- Hook injection ---
if $JQ_OK; then
    step "Injecting cmux hooks into agents..."

    has_all_cmux_hooks() {
        local f="$1"
        local count=$(jq '[.hooks.agentSpawn, .hooks.userPromptSubmit, .hooks.preToolUse, .hooks.postToolUse, .hooks.stop | select(. != null) | map(select(.command | contains("cmux-notify.sh"))) | select(length > 0)] | length' "$f" 2>/dev/null)
        [ "$count" -eq 5 ]
    }

    HOOK_CMD="$INSTALL_DIR/hooks/cmux-notify.sh"
    EVENTS="agentSpawn userPromptSubmit preToolUse postToolUse stop"
    SKIP_AGENTS="cmux.json cmux-titler.json cmux-notifier.json fast.json"
    ELIGIBLE=()

    for f in ~/.kiro/agents/*.json; do
        [ -f "$f" ] || continue
        bn=$(basename "$f")
        echo "$SKIP_AGENTS" | grep -qw "$bn" && continue
        if [ -L "$f" ]; then
            target=$(readlink "$f" 2>/dev/null)
            echo "$target" | grep -q "AmznCmuxKiroTools\|cmux-kiro" && continue
        fi
        jq empty "$f" 2>/dev/null || continue
        has_all_cmux_hooks "$f" && continue
        ELIGIBLE+=("$bn")
    done

    if [ "${#ELIGIBLE[@]}" -gt 0 ]; then
        echo "  Agents to hook: ${ELIGIBLE[*]}"
        read -p "  Inject cmux hooks into these agents? [Y/n] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            UPDATED=0
            for bn in "${ELIGIBLE[@]}"; do
                f="$HOME/.kiro/agents/$bn"
                jq_filter='. | if .hooks == null then .hooks = {} else . end'
                for evt in $EVENTS; do
                    jq_filter+=" | if (.hooks.${evt} // [] | map(select(.command | contains(\"cmux-notify.sh\"))) | length) == 0"
                    jq_filter+=" then .hooks.${evt} = (.hooks.${evt} // []) + [{\"command\": \"${HOOK_CMD}\", \"description\": \"cmux sidebar integration\"}]"
                    jq_filter+=" else . end"
                done
                if result=$(jq "$jq_filter" "$f" 2>/dev/null); then
                    echo "$result" > "$f"
                    info "Hooked $bn"
                    ((UPDATED++)) || true
                else
                    warn "Skipped $bn (jq failed)"
                fi
            done
            info "Updated $UPDATED agents"
        fi
    else
        info "All agents already have cmux hooks"
    fi
else
    warn "Skipping hook injection (jq not installed)"
fi

# --- Install kask ---
step "Setting up kask..."
if [ -f "$REPO_DIR/bin/kiro-acp-client.py" ]; then
    cp "$REPO_DIR/bin/kiro-acp-client.py" ~/bin/kiro-acp-client.py
    chmod +x ~/bin/kiro-acp-client.py
    info "Installed kiro-acp-client.py → ~/bin/"
fi

if [ -f "$REPO_DIR/bin/kiro-cmux" ]; then
    cp "$REPO_DIR/bin/kiro-cmux" ~/bin/kiro-cmux
    chmod +x ~/bin/kiro-cmux
    ln -sf ~/bin/kiro-cmux ~/bin/kmux
    info "Installed kiro-cmux (+ kmux alias) → ~/bin/"
fi

# --- Shell aliases ---
step "Checking shell aliases..."
ALIAS_LINE='alias k="kiro-cli chat -a --agent cmux"'
KASK_ALIAS='alias kask="python3 ~/bin/kiro-acp-client.py"'

if grep -q 'alias k=.*--agent cmux' ~/.zshrc 2>/dev/null || grep -qF 'CMUX_WORKSPACE_ID:+--agent' ~/.zshrc 2>/dev/null; then
    info "'k' alias already configured in ~/.zshrc"
elif grep -qF 'alias k=' ~/.zshrc 2>/dev/null; then
    warn "'k' alias exists but doesn't use --agent cmux"
    read -p "  Update 'k' alias to use the cmux agent? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        sed -i'' 's|^alias k=.*|'"$ALIAS_LINE"'|' ~/.zshrc
        info "Updated 'k' alias in ~/.zshrc"
    else
        warn "Skipped — you can update it manually:"
        echo "  $ALIAS_LINE"
    fi
else
    echo "" >> ~/.zshrc
    echo "# kiro-cmux: shorthand for the cmux agent" >> ~/.zshrc
    echo "$ALIAS_LINE" >> ~/.zshrc
    info "Added 'k' alias to ~/.zshrc"
fi

if grep -qF 'kiro-acp-client.py' ~/.zshrc 2>/dev/null; then
    info "'kask' alias already configured in ~/.zshrc"
else
    echo "" >> ~/.zshrc
    echo "# kask: warm kiro ACP client" >> ~/.zshrc
    echo "$KASK_ALIAS" >> ~/.zshrc
    info "Added 'kask' alias to ~/.zshrc"
fi

# --- Summary ---
VER=$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo "unknown")
step "Remote setup complete! (v$VER)"
echo ""
echo "To connect from your laptop (inside cmux):"
echo ""
echo -e "  ${BOLD}cmux-ssh $(hostname -s)${NC}"
echo ""
echo "Or add to ~/.ssh/config on your laptop:"
echo ""
echo "  Host $(hostname -s)"
echo "      RemoteForward /tmp/cmux.sock <your-cmux-socket-path>"
echo "      StreamLocalBindUnlink yes"
echo ""
echo "Then: ssh $(hostname -s) && kiro-cli chat -a"

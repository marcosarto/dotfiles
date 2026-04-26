#!/usr/bin/env bash
# setup-remote-push.sh — Set up kiro-cmux on a remote host, entirely from the laptop.
# Usage: kmux setup-remote <hostname>
set -euo pipefail

HOST="${1:?Usage: kmux setup-remote <hostname>}"
INSTALL_DIR="$HOME/.cmux-kiro"

BOLD='\033[1m' NC='\033[0m' GREEN='\033[0;32m' YELLOW='\033[0;33m' RED='\033[0;31m'
step()  { echo -e "\n${BOLD}▸ $1${NC}"; }
info()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
err()   { echo -e "  ${RED}✗${NC} $1"; }

VER=$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo "unknown")
echo -e "${BOLD}kmux remote setup${NC} v$VER"
echo "Setting up kiro-cmux on $HOST"

# --- Preflight ---
step "Checking SSH connectivity..."
if ! ssh -o ConnectTimeout=5 "$HOST" "echo ok" >/dev/null 2>&1; then
    err "Cannot SSH to $HOST"
    exit 1
fi
info "Connected to $HOST"

# --- Check remote prerequisites ---
step "Checking remote prerequisites..."
REMOTE_CHECK=$(ssh "$HOST" "
    echo \"python3=\$(command -v python3 2>/dev/null || echo MISSING)\"
    echo \"jq=\$(command -v jq 2>/dev/null || echo MISSING)\"
    echo \"kiro=\$(command -v kiro-cli 2>/dev/null || echo MISSING)\"
    # Also check common kiro-cli locations
    [ -f ~/.local/bin/kiro-cli ] && echo 'kiro_local=yes' || echo 'kiro_local=no'
")
eval "$REMOTE_CHECK"

[ "$python3" = "MISSING" ] && { err "python3 not found on $HOST"; exit 1; }
info "python3 found"
[ "$jq" = "MISSING" ] && warn "jq not found — hook injection will be skipped (install: sudo yum install -y jq)" || info "jq found"
[ "$kiro" = "MISSING" ] && [ "$kiro_local" = "no" ] && warn "kiro-cli not found — install from https://kiro.dev" || info "kiro-cli found"

# --- Check for stale k alias (prompt early so user doesn't miss it) ---
UPDATE_K_ALIAS=false
K_ALIAS_STATE=$(ssh "$HOST" "
    if grep -q 'alias k=.*--agent cmux' ~/.zshrc 2>/dev/null || grep -qF 'CMUX_WORKSPACE_ID:+--agent' ~/.zshrc 2>/dev/null; then
        echo 'OK'
    elif grep -qF 'alias k=' ~/.zshrc 2>/dev/null; then
        echo 'STALE'
    else
        echo 'MISSING'
    fi
")
if [ "$K_ALIAS_STATE" = "STALE" ]; then
    warn "'k' alias on $HOST doesn't use --agent cmux"
    read -p "  Update 'k' alias to use the cmux agent? [Y/n] " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Nn]$ ]] && UPDATE_K_ALIAS=true
fi

# --- Sync repo from local ---
step "Syncing kiro-cmux to $HOST..."
ssh "$HOST" "mkdir -p ~/.cmux-kiro"
rsync -az --delete \
    --exclude='.git' \
    --exclude='node_modules' \
    "$INSTALL_DIR/" "$HOST:~/.cmux-kiro/"
info "Synced local ~/.cmux-kiro → $HOST:~/.cmux-kiro"

# --- Install ghostty terminfo ---
step "Installing terminal info..."
if command -v infocmp &>/dev/null && infocmp -x xterm-ghostty &>/dev/null 2>&1; then
    if infocmp -x xterm-ghostty 2>/dev/null | ssh "$HOST" "tic -x - 2>/dev/null"; then
        info "Installed xterm-ghostty terminfo"
    else
        warn "Could not install terminfo (tic failed on remote)"
    fi
else
    warn "xterm-ghostty terminfo not available locally — skipping"
fi

# --- Install shims ---
step "Installing shims..."
ssh "$HOST" "
    mkdir -p ~/bin
    cp ~/.cmux-kiro/lib/remote/cmux-shim ~/bin/cmux
    cp ~/.cmux-kiro/lib/remote/nc-shim ~/bin/nc
    chmod +x ~/bin/cmux ~/bin/nc
"
info "cmux shim → ~/bin/cmux"
info "nc shim   → ~/bin/nc"

# --- Ensure ~/bin in PATH ---
ssh "$HOST" "
    if ! echo \"\$PATH\" | tr ':' '\n' | grep -qx \"\$HOME/bin\"; then
        if ! grep -qF 'HOME/bin' ~/.zshrc 2>/dev/null && ! grep -qF 'HOME/bin' ~/.bashrc 2>/dev/null; then
            RC=~/.zshrc; [ -f \"\$RC\" ] || RC=~/.bashrc
            echo '' >> \"\$RC\"
            echo '# kiro-cmux: add ~/bin to PATH' >> \"\$RC\"
            echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> \"\$RC\"
            echo 'ADDED_PATH'
        fi
    fi
" | grep -q 'ADDED_PATH' && info "Added ~/bin to PATH in shell rc" || info "~/bin already in PATH"

# --- Agent configs ---
step "Setting up agent configs..."
ssh "$HOST" "
    mkdir -p ~/.kiro/agents
    INSTALL_DIR=~/.cmux-kiro

    # Generate cmux.json from template
    if [ -f \"\$INSTALL_DIR/agents/cmux.json.template\" ]; then
        sed \"s|__INSTALL_DIR__|\$INSTALL_DIR|g; s|__HOME__|\$HOME|g\" \\
            \"\$INSTALL_DIR/agents/cmux.json.template\" > ~/.kiro/agents/cmux.json
        echo 'GEN cmux.json'
    fi

    # Symlink supporting agents
    for agent in cmux-titler.json cmux-notifier.json cmux-activity.json fast.json; do
        [ -f \"\$INSTALL_DIR/agents/\$agent\" ] && ln -sf \"\$INSTALL_DIR/agents/\$agent\" ~/.kiro/agents/\"\$agent\" && echo \"LINK \$agent\"
    done

    # Install steering file
    mkdir -p ~/.kiro/steering
    if [ -f \"\$INSTALL_DIR/steering/cmux-kiro-usage.md\" ]; then
        ln -sf \"\$INSTALL_DIR/steering/cmux-kiro-usage.md\" ~/.kiro/steering/cmux-kiro-usage.md
        echo 'STEER cmux-kiro-usage.md'
    fi
" | while read -r line; do
    case "$line" in
        GEN*)   info "Generated ${line#GEN }" ;;
        LINK*)  info "Linked ${line#LINK }" ;;
        STEER*) info "Linked ${line#STEER } → ~/.kiro/steering/" ;;
    esac
done

# --- Hook injection ---
step "Injecting cmux hooks into agents..."
HOOK_RESULT=$(ssh "$HOST" "
    [ ! -x \"\$(command -v jq 2>/dev/null)\" ] && echo 'SKIP no jq' && exit 0

    INSTALL_DIR=~/.cmux-kiro
    HOOK_CMD=\"\$INSTALL_DIR/hooks/cmux-notify.sh\"
    EVENTS='agentSpawn userPromptSubmit preToolUse postToolUse stop'
    SKIP='cmux.json cmux-titler.json cmux-notifier.json fast.json'

    has_all() {
        local c=\$(jq '[.hooks.agentSpawn, .hooks.userPromptSubmit, .hooks.preToolUse, .hooks.postToolUse, .hooks.stop | select(. != null) | map(select(.command | contains(\"cmux-notify.sh\"))) | select(length > 0)] | length' \"\$1\" 2>/dev/null)
        [ \"\$c\" -eq 5 ]
    }

    UPDATED=0
    for f in ~/.kiro/agents/*.json; do
        [ -f \"\$f\" ] || continue
        bn=\$(basename \"\$f\")
        echo \"\$SKIP\" | grep -qw \"\$bn\" && continue
        [ -L \"\$f\" ] && readlink \"\$f\" 2>/dev/null | grep -q 'AmznCmuxKiroTools\|cmux-kiro' && continue
        jq empty \"\$f\" 2>/dev/null || continue
        has_all \"\$f\" && continue

        jq_filter='. | if .hooks == null then .hooks = {} else . end'
        for evt in \$EVENTS; do
            jq_filter+=\" | if (.hooks.\${evt} // [] | map(select(.command | contains(\\\"cmux-notify.sh\\\"))) | length) == 0\"
            jq_filter+=\" then .hooks.\${evt} = (.hooks.\${evt} // []) + [{\\\"command\\\": \\\"\${HOOK_CMD}\\\", \\\"description\\\": \\\"cmux sidebar integration\\\"}]\"
            jq_filter+=\" else . end\"
        done

        if result=\$(jq \"\$jq_filter\" \"\$f\" 2>/dev/null); then
            echo \"\$result\" > \"\$f\"
            echo \"HOOKED \$bn\"
            ((UPDATED++)) || true
        fi
    done
    [ \"\$UPDATED\" -eq 0 ] && echo 'ALL_HOOKED'
")
while IFS= read -r line; do
    case "$line" in
        SKIP*)     warn "Skipping hook injection (jq not installed on remote)" ;;
        HOOKED*)   info "Hooked ${line#HOOKED }" ;;
        ALL_HOOKED) info "All agents already have cmux hooks" ;;
    esac
done <<< "$HOOK_RESULT"

# --- Install kask ---
step "Installing kask..."
ssh "$HOST" "
    mkdir -p ~/bin
    [ -f ~/.cmux-kiro/bin/kiro-acp-client.py ] && cp ~/.cmux-kiro/bin/kiro-acp-client.py ~/bin/ && chmod +x ~/bin/kiro-acp-client.py && echo OK || echo MISSING
" | grep -q OK && info "Installed kiro-acp-client.py → ~/bin/" || warn "kiro-acp-client.py missing"

# --- Install kmux CLI ---
step "Installing kmux CLI..."
ssh "$HOST" "
    mkdir -p ~/bin
    [ -f ~/.cmux-kiro/bin/kiro-cmux ] && cp ~/.cmux-kiro/bin/kiro-cmux ~/bin/kiro-cmux && chmod +x ~/bin/kiro-cmux && ln -sf ~/bin/kiro-cmux ~/bin/kmux && echo OK || echo MISSING
" | grep -q OK && info "Installed kiro-cmux (+ kmux alias) → ~/bin/" || warn "kiro-cmux missing"

# --- Shell aliases ---
step "Setting up shell aliases..."
ALIAS_RESULT=$(ssh "$HOST" "
    if grep -q 'alias k=.*--agent cmux' ~/.zshrc 2>/dev/null || grep -qF 'CMUX_WORKSPACE_ID:+--agent' ~/.zshrc 2>/dev/null; then
        echo 'K_EXISTS'
    elif grep -qF 'alias k=' ~/.zshrc 2>/dev/null; then
        echo 'K_STALE'
    else
        echo '' >> ~/.zshrc
        echo '# kiro-cmux: shorthand for the cmux agent' >> ~/.zshrc
        echo 'alias k=\"kiro-cli chat -a --agent cmux\"' >> ~/.zshrc
        echo 'K_ADDED'
    fi
    if grep -qF 'kiro-acp-client.py' ~/.zshrc 2>/dev/null; then
        echo 'KASK_EXISTS'
    else
        echo '' >> ~/.zshrc
        echo '# kask: warm kiro ACP client' >> ~/.zshrc
        echo 'alias kask=\"python3 ~/bin/kiro-acp-client.py\"' >> ~/.zshrc
        echo 'KASK_ADDED'
    fi
")
while IFS= read -r line; do
    case "$line" in
        K_EXISTS)    info "'k' alias already configured" ;;
        K_ADDED)     info "Added 'k' alias to ~/.zshrc" ;;
        K_STALE)     if $UPDATE_K_ALIAS; then
                         ssh "$HOST" "sed -i'' 's|^alias k=.*|alias k=\"kiro-cli chat -a --agent cmux\"|' ~/.zshrc"
                         info "Updated 'k' alias on $HOST"
                     else
                         warn "'k' alias not updated — run on remote to fix:"
                         echo "      sed -i'' 's|^alias k=.*|alias k=\"kiro-cli chat -a --agent cmux\"|' ~/.zshrc"
                     fi ;;
        KASK_EXISTS) info "'kask' alias already configured" ;;
        KASK_ADDED)  info "Added 'kask' alias to ~/.zshrc" ;;
    esac
done <<< "$ALIAS_RESULT"

# --- CR detection ---
step "Setting up CR detection..."
CR_RESULT=$(ssh "$HOST" "
    INSTALL_DIR=~/.cmux-kiro

    # Source cr-wrapper.sh in .zshrc
    if grep -qF 'cr-wrapper.sh' ~/.zshrc 2>/dev/null; then
        echo 'WRAPPER_EXISTS'
    else
        echo '' >> ~/.zshrc
        echo '# kiro-cmux: detect CRs created outside Kiro' >> ~/.zshrc
        echo \"source \$INSTALL_DIR/lib/cr-wrapper.sh\" >> ~/.zshrc
        echo 'WRAPPER_ADDED'
    fi

    # CRUX pre-cr hook
    PRE_CR_DIR=~/.config/cr/hooks
    PRE_CR_FILE=\$PRE_CR_DIR/pre-cr
    if [ -L \"\$PRE_CR_FILE\" ] && readlink \"\$PRE_CR_FILE\" 2>/dev/null | grep -q 'cmux-kiro'; then
        echo 'PRECR_EXISTS'
    elif [ -f \"\$PRE_CR_FILE\" ]; then
        echo 'PRECR_CONFLICT'
    else
        mkdir -p \"\$PRE_CR_DIR\"
        ln -sf \"\$INSTALL_DIR/hooks/pre-cr\" \"\$PRE_CR_FILE\"
        echo 'PRECR_LINKED'
    fi
")
while IFS= read -r line; do
    case "$line" in
        WRAPPER_EXISTS) info "CR wrapper already in .zshrc" ;;
        WRAPPER_ADDED)  info "Added CR wrapper to .zshrc" ;;
        PRECR_EXISTS)   info "CRUX pre-cr hook already linked" ;;
        PRECR_CONFLICT) warn "pre-cr hook exists but isn't ours — skipping" ;;
        PRECR_LINKED)   info "Linked CRUX pre-cr hook" ;;
    esac
done <<< "$CR_RESULT"

# --- Record remote host for future updates ---
REMOTES_FILE="$INSTALL_DIR/.remote-hosts"
if ! grep -qxF "$HOST" "$REMOTES_FILE" 2>/dev/null; then
    echo "$HOST" >> "$REMOTES_FILE"
fi

# --- Done ---
REMOTE_SHORT=$(ssh "$HOST" "hostname -s")
step "Remote setup complete!"
echo ""
echo "To connect (from inside cmux):"
echo ""
echo -e "  ${BOLD}kmux ssh $HOST${NC}"
echo ""
echo "Then on $REMOTE_SHORT:"
echo ""
echo -e "  ${BOLD}k${NC}"
echo ""

# --- Offer kssh alias ---
KSSH_LINE="alias kssh=\"kmux ssh $HOST\""
if grep -qF "alias kssh=" ~/.zshrc 2>/dev/null; then
    if grep -qF "kmux ssh $HOST" ~/.zshrc 2>/dev/null; then
        info "'kssh' alias already configured"
    else
        warn "'kssh' alias exists but points to a different host"
    fi
elif command -v kssh >/dev/null 2>&1; then
    warn "'kssh' already exists as a command — skipping alias"
else
    read -p "Add 'kssh' alias to ~/.zshrc? (shorthand for kmux ssh $HOST) [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo "" >> ~/.zshrc
        echo "# kiro-cmux: quick SSH to $HOST" >> ~/.zshrc
        echo "$KSSH_LINE" >> ~/.zshrc
        info "Added 'kssh' alias to ~/.zshrc — restart shell or: source ~/.zshrc"
    fi
fi

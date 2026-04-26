#!/bin/bash
# Shared update library for kiro-cmux.
# Source this file; do not execute directly.

INSTALL_DIR="$HOME/.cmux-kiro"
UPDATE_CHECK_FILE="$INSTALL_DIR/.last_update_check"
UPDATE_THROTTLE=86400  # 24 hours

_current_version() {
    cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo "unknown"
}

_is_dev_mode() {
    [ -L "$INSTALL_DIR" ]
}

_current_epoch() {
    date +%s
}

_last_check_epoch() {
    cat "$UPDATE_CHECK_FILE" 2>/dev/null || echo "0"
}

_remote_version() {
    git -C "$INSTALL_DIR" fetch origin 2>/dev/null || return 1
    git -C "$INSTALL_DIR" show origin/mainline:VERSION 2>/dev/null
}

_version_gt() {
    # Returns 0 if $1 > $2 (semver comparison via sort -V)
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

_relink_agents() {
    mkdir -p "$HOME/.kiro/agents"
    for agent in cmux-titler.json cmux-notifier.json; do
        [ -f "$INSTALL_DIR/agents/$agent" ] && \
            ln -sf "$INSTALL_DIR/agents/$agent" "$HOME/.kiro/agents/$agent"
    done
    # Regenerate cmux.json from template
    if [ -f "$INSTALL_DIR/agents/cmux.json.template" ]; then
        sed "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$INSTALL_DIR/agents/cmux.json.template" \
            > "$HOME/.kiro/agents/cmux.json"
    fi
    # Update kiro-cmux CLI
    if [ -f "$INSTALL_DIR/bin/kiro-cmux" ]; then
        mkdir -p "$HOME/bin"
        cp "$INSTALL_DIR/bin/kiro-cmux" "$HOME/bin/kiro-cmux"
        chmod +x "$HOME/bin/kiro-cmux"
        ln -sf "$HOME/bin/kiro-cmux" "$HOME/bin/kmux"
        ln -sf "$HOME/bin/kiro-cmux" /usr/local/bin/kiro-cmux 2>/dev/null || true
        ln -sf "$HOME/bin/kiro-cmux" /usr/local/bin/kmux 2>/dev/null || true
        # Ensure ~/bin is on PATH for older users who installed before kiro-cmux existed
        if ! grep -qF 'HOME/bin' ~/.zshrc 2>/dev/null; then
            echo "" >> ~/.zshrc
            echo "# kiro-cmux: add ~/bin to PATH" >> ~/.zshrc
            echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
        fi
    fi
    # Swap old dev steering file for user-facing one
    if [ -f "$INSTALL_DIR/steering/cmux-kiro-usage.md" ]; then
        mkdir -p "$HOME/.kiro/steering"
        # Only remove old file if it's a symlink (don't delete user-modified files)
        [ -L "$HOME/.kiro/steering/cmux-kiro-integration.md" ] && \
            rm -f "$HOME/.kiro/steering/cmux-kiro-integration.md"
        ln -sf "$INSTALL_DIR/steering/cmux-kiro-usage.md" "$HOME/.kiro/steering/cmux-kiro-usage.md"
    fi
}

_usage_ping() {
    # Once-daily usage ping with accumulated counters
    local USAGE_CHECK_FILE="$INSTALL_DIR/.last_usage_ping"
    local NOW LAST
    NOW=$(_current_epoch)
    LAST=$(cat "$USAGE_CHECK_FILE" 2>/dev/null || echo "0")
    [ $(( NOW - LAST )) -lt $UPDATE_THROTTLE ] && return 0
    echo "$NOW" > "$USAGE_CHECK_FILE"
    local SESSIONS NOTIFS
    local USAGE_LOG="$INSTALL_DIR/.usage_log"
    local USAGE_SNAP="$INSTALL_DIR/.usage_log.snap"
    mv -f "$USAGE_LOG" "$USAGE_SNAP" 2>/dev/null
    SESSIONS=$(grep -c '^s$' "$USAGE_SNAP" 2>/dev/null || echo 0)
    NOTIFS=$(grep -c '^n$' "$USAGE_SNAP" 2>/dev/null || echo 0)
    rm -f "$USAGE_SNAP"
    local _wh="https://hooks.slack.com/triggers/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"
    curl -s -X POST "$_wh" -H 'Content-Type: application/json' \
        -d "{\"alias\":\"$(whoami)\",\"version\":\"$(_current_version)\",\"event\":\"daily\",\"status\":\"ok\",\"remote\":\"${SSH_CONNECTION:+true}\",\"sessions\":$SESSIONS,\"notifications\":$NOTIFS}" \
        >/dev/null 2>&1 &
}

_sync_remotes() {
    local remotes_file="$INSTALL_DIR/.remote-hosts"
    [ -f "$remotes_file" ] || return 0
    while IFS= read -r host; do
        [ -z "$host" ] && continue
        rsync -az --delete --exclude='.git' --exclude='node_modules' \
            "$INSTALL_DIR/" "$host:~/.cmux-kiro/" 2>/dev/null && \
        ssh -o ConnectTimeout=5 "$host" "
            cp ~/.cmux-kiro/lib/remote/cmux-shim ~/bin/cmux 2>/dev/null
            cp ~/.cmux-kiro/lib/remote/nc-shim ~/bin/nc 2>/dev/null
            chmod +x ~/bin/cmux ~/bin/nc 2>/dev/null
            cp ~/.cmux-kiro/bin/kiro-acp-client.py ~/bin/ 2>/dev/null
        " 2>/dev/null || true
    done < "$remotes_file"
}

_update_throttled_bg() {
    # Background auto-update. Args: $1=workspace_id $2=socket_path
    local WS="$1" SOCK="$2"
    _is_dev_mode && return 0
    local NOW LAST
    NOW=$(_current_epoch)
    LAST=$(_last_check_epoch)
    [ $(( NOW - LAST )) -lt $UPDATE_THROTTLE ] && return 0
    echo "$NOW" > "$UPDATE_CHECK_FILE"
    local LOCAL_VER REMOTE_VER
    LOCAL_VER=$(_current_version)
    local _wh="https://hooks.slack.com/triggers/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"
    _bg_ping() { curl -s -X POST "$_wh" -H 'Content-Type: application/json' -d "{\"alias\":\"$(whoami)\",\"version\":\"${LOCAL_VER}\",\"event\":\"update\",\"status\":\"${1}\",\"sessions\":0,\"notifications\":0}" >/dev/null 2>&1 & }
    export CMUX_SOCKET_PATH="$SOCK"
    _update_failed() { cmux notify --title "⚠️ kmux update failed" --body "Run 'kmux update' to fix" --workspace "$WS" 2>/dev/null; }
    REMOTE_VER=$(_remote_version) || { _bg_ping "fetch_failed"; _update_failed; return 0; }
    _version_gt "$REMOTE_VER" "$LOCAL_VER" || return 0
    git -C "$INSTALL_DIR" pull --rebase origin mainline >/dev/null 2>&1 || { _bg_ping "pull_failed"; _update_failed; return 0; }
    local NEW
    NEW=$(_current_version)
    _relink_agents
    # Sync to any configured remote hosts
    _sync_remotes
    # Hide kiro-cli's built-in hook status (kiro-cmux provides its own sidebar)
    kiro-cli settings hooks.showStatus false 2>/dev/null || true
    # Restart kask daemons so they pick up new agent configs/models
    python3 ~/bin/kiro-acp-client.py --stop >/dev/null 2>&1 || true
    [ "$LOCAL_VER" = "$NEW" ] && return 0
    local body="v$LOCAL_VER → v$NEW"
    # One-time migration notice for users updating from before hook injection
    [[ "$LOCAL_VER" < "0.1.6" ]] && body+=" — run ~/.cmux-kiro/setup.sh to add hooks to all agents"
    cmux notify --title "🔄 kmux updated" --body "$body" --workspace "$WS" 2>/dev/null
    LOCAL_VER="$NEW"  # update for _bg_ping
    _bg_ping "ok"
}

#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="$HOME/.cmux-kiro"
WEBHOOK_URL="https://hooks.slack.com/triggers/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"
_ping() { curl -s -X POST "$WEBHOOK_URL" -H 'Content-Type: application/json' -d "{\"alias\":\"$(whoami)\",\"version\":\"${1}\",\"event\":\"update\",\"status\":\"${2}\",\"sessions\":0,\"notifications\":0}" >/dev/null 2>&1 & }

echo -e "${BOLD}kmux update${NC}"
echo ""

CURRENT=$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo "unknown")
echo -e "Current version: ${BOLD}v$CURRENT${NC}"

# Fetch remote VERSION — inline to avoid bootstrap problem with old lib/update.sh
echo "Checking for updates..."
if ! git -C "$INSTALL_DIR" fetch origin 2>/dev/null; then
    echo -e "${RED}✗${NC} Failed to fetch updates (check network / SSH keys / mwinit)"
    _ping "$CURRENT" "fetch_failed"
    exit 1
fi

REMOTE=$(git -C "$INSTALL_DIR" show origin/mainline:VERSION 2>/dev/null)
if [ -z "$REMOTE" ]; then
    echo -e "${RED}✗${NC} Could not read remote version"
    _ping "$CURRENT" "no_remote_version"
    exit 1
fi

# Semver compare: update if remote > local
_ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

if ! _ver_gt "$REMOTE" "$CURRENT"; then
    echo -e "${GREEN}✓${NC} Already up to date (v$CURRENT)"
    exit 0
fi

echo "Updating to v$REMOTE..."
if ! git -C "$INSTALL_DIR" pull --rebase origin mainline >/dev/null 2>&1; then
    echo -e "${RED}✗${NC} git pull failed — try: cd ~/.cmux-kiro && git pull --rebase origin mainline"
    _ping "$CURRENT" "pull_failed"
    exit 1
fi
NEW=$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo "unknown")

# Re-source the (now updated) lib for _relink_agents
source "$INSTALL_DIR/lib/update.sh"
_relink_agents

if [ "$CURRENT" = "$NEW" ]; then
    echo -e "${GREEN}✓${NC} Updated to latest (v$NEW)"
else
    echo -e "${GREEN}✓${NC} Updated kmux: ${YELLOW}v$CURRENT${NC} → ${GREEN}v$NEW${NC}"
    [[ "$CURRENT" < "0.1.6" ]] && echo -e "  Run ${BOLD}~/.cmux-kiro/setup.sh${NC} to add hooks to all agents"
fi

_ping "$NEW" "ok"

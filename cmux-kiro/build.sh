#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'
PASS=0 FAIL=0

pass() { echo -e "${GREEN}✓${NC} $1"; ((PASS++)) || true; }
fail() { echo -e "${RED}✗${NC} $1"; ((FAIL++)) || true; }

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

echo "=== Syntax checks ==="
for f in hooks/*.sh lib/*.sh setup.sh update.sh; do
    if bash -n "$f" 2>/dev/null; then
        pass "$f"
    else
        fail "$f syntax error"
    fi
done

echo ""
echo "=== Template validation ==="
if [ -f agents/cmux.json.template ]; then
    grep -q '__INSTALL_DIR__' agents/cmux.json.template && pass "template has __INSTALL_DIR__" || fail "missing __INSTALL_DIR__"
    grep -q '__HOME__' agents/cmux.json.template && pass "template has __HOME__" || fail "missing __HOME__"
    if sed 's|__INSTALL_DIR__|/tmp/test|g; s|__HOME__|/tmp|g' agents/cmux.json.template | python3 -m json.tool >/dev/null 2>&1; then
        pass "template expands to valid JSON"
    else
        fail "template produces invalid JSON"
    fi
    if grep -q '/Volumes/workplace\|/Users/' agents/cmux.json.template; then
        fail "hardcoded paths in template"
    else
        pass "no hardcoded paths in template"
    fi
else
    fail "cmux.json.template missing"
fi

echo ""
echo "=== Agent JSON validation ==="
for f in agents/cmux-titler.json agents/cmux-notifier.json; do
    if [ -f "$f" ] && python3 -m json.tool "$f" >/dev/null 2>&1; then
        pass "$f"
    else
        fail "$f invalid"
    fi
done

echo ""
echo "=== VERSION file ==="
if [ -f VERSION ] && grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' VERSION; then
    pass "VERSION $(cat VERSION)"
else
    fail "VERSION missing or malformed"
fi

echo ""
echo "=== Update library ==="
source lib/update.sh
for fn in _current_version _update_throttled_bg _relink_agents; do
    if [ "$(type -t $fn)" = "function" ]; then
        pass "$fn defined"
    else
        fail "$fn missing"
    fi
done

echo ""
echo "=== Bump version ==="
# Only bump for user-facing changes, and only once per set of changes
CHANGED_FILES=$(git -C "$REPO_DIR" diff --name-only HEAD -- hooks/ lib/ agents/ setup.sh update.sh README.md .kiro/ 2>/dev/null)
COMMITTED_VERSION=$(git -C "$REPO_DIR" show HEAD:VERSION 2>/dev/null || echo "0.0.0")
CURRENT_VERSION=$(cat VERSION)
if [ -z "$CHANGED_FILES" ]; then
    pass "VERSION $CURRENT_VERSION (no user-facing changes)"
elif [ "$CURRENT_VERSION" != "$COMMITTED_VERSION" ]; then
    pass "VERSION $CURRENT_VERSION (already bumped from $COMMITTED_VERSION)"
else
    IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
    NEW="$MAJOR.$MINOR.$((PATCH + 1))"
    echo "$NEW" > VERSION
    pass "VERSION $CURRENT_VERSION → $NEW (changed: $(echo $CHANGED_FILES | tr '\n' ' '))"
fi

echo ""
echo "=== Results ==="
echo -e "${BOLD}$PASS passed, $FAIL failed${NC}"
[ $FAIL -eq 0 ] && exit 0 || exit 1

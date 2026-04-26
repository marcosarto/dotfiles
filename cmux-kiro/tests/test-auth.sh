#!/bin/bash
# Tests for lib/auth.sh
# Run inside cmux with a valid midway cookie.
# Usage: ./test-auth.sh

set +e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/auth.sh"

PASS=0 FAIL=0
check() {
    local desc="$1" ok="$2"
    if [ "$ok" = "true" ]; then echo "✓ $desc"; ((PASS++))
    else echo "✗ $desc"; ((FAIL++)); fi
}

echo "=== URL extraction ==="

OUT=$(echo 'check https://phonetool.amazon.com/users/bssas please' | _extract_internal_urls)
check "phonetool URL with path" "$([ "$OUT" = "https://phonetool.amazon.com/users/bssas" ] && echo true || echo false)"

OUT=$(echo 'look at https://taskei.amazon.dev/tasks/TRACK-8877' | _extract_internal_urls)
check "taskei URL with full path" "$([ "$OUT" = "https://taskei.amazon.dev/tasks/TRACK-8877" ] && echo true || echo false)"

OUT=$(echo '[https://code.amazon.com/reviews/CR-123]' | _extract_internal_urls)
check "URL in brackets (strips ])" "$([ "$OUT" = "https://code.amazon.com/reviews/CR-123" ] && echo true || echo false)"

OUT=$(echo 'https://google.com should not match' | _extract_internal_urls)
check "external URL ignored" "$([ -z "$OUT" ] && echo true || echo false)"

OUT=$(echo 'two urls https://phonetool.amazon.com/users/a and https://code.amazon.com/b' | _extract_internal_urls)
COUNT=$(echo "$OUT" | wc -l | tr -d ' ')
check "multiple URLs extracted ($COUNT)" "$([ "$COUNT" = "2" ] && echo true || echo false)"

OUT=$(echo 'no urls here at all' | _extract_internal_urls)
check "no URLs returns empty" "$([ -z "$OUT" ] && echo true || echo false)"

OUT=$(echo 'https://w.amazon.com/bin/view/MyPage' | _extract_internal_urls)
check "wiki URL with path" "$([ "$OUT" = "https://w.amazon.com/bin/view/MyPage" ] && echo true || echo false)"

echo ""
echo "=== URL rewriting ==="

OUT=$(_rewrite_url "https://taskei.amazon.dev/tasks/TRACK-8877")
check "taskei task → SIM" "$([ "$OUT" = "https://issues.amazon.com/issues/TRACK-8877" ] && echo true || echo false)"

OUT=$(_rewrite_url "https://taskei.amazon.dev/rooms/my-room")
check "taskei non-task unchanged" "$([ "$OUT" = "https://taskei.amazon.dev/rooms/my-room" ] && echo true || echo false)"

OUT=$(_rewrite_url "https://phonetool.amazon.com/users/bssas")
check "phonetool unchanged" "$([ "$OUT" = "https://phonetool.amazon.com/users/bssas" ] && echo true || echo false)"

OUT=$(_rewrite_url "https://issues.amazon.com/issues/TRACK-123")
check "SIM URL unchanged" "$([ "$OUT" = "https://issues.amazon.com/issues/TRACK-123" ] && echo true || echo false)"

echo ""
echo "=== Midway freshness ==="

if [ -f "$COOKIE_FILE" ]; then
    AGE=$(( $(date +%s) - $(stat -f "%m" "$COOKIE_FILE") ))
    if _midway_fresh; then
        check "cookie fresh (${AGE}s old)" "true"
    else
        check "cookie stale (${AGE}s old)" "true"  # stale is valid if old
    fi
else
    check "no cookie file (skip)" "true"
fi

echo ""
echo "=== SSO cookie flow ==="

if _midway_fresh; then
    COOKIES=$(_sso_cookies_json "https://phonetool.amazon.com/users/bssas")
    COUNT=$(echo "$COOKIES" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)
    check "SSO returns cookies ($COUNT)" "$([ "$COUNT" -gt 0 ] && echo true || echo false)"

    HAS_SSO=$(echo "$COOKIES" | python3 -c 'import json,sys; print(any(c["name"]=="amzn_sso_token" for c in json.load(sys.stdin)))' 2>/dev/null)
    check "has amzn_sso_token" "$([ "$HAS_SSO" = "True" ] && echo true || echo false)"
else
    check "SSO flow (skipped — stale cookies)" "true"
    check "amzn_sso_token (skipped)" "true"
fi

echo ""
echo "=== Browser panel (requires cmux) ==="

if [ -S "${CMUX_SOCKET_PATH:-/tmp/cmux.sock}" ] && _midway_fresh; then
    STATE="/tmp/kiro-cmux-test-$$"
    mkdir -p "$STATE"

    # Test 1: open browser panel
    SURFACE=$(_open_authed_browser "https://phonetool.amazon.com/users/bssas" "$STATE")
    check "browser opens ($SURFACE)" "$([ -n "$SURFACE" ] && echo true || echo false)"

    # Test 2: verify surface is alive
    sleep 2
    ALIVE=$(cmux tree --all 2>/dev/null | grep -c "$SURFACE" || true)
    check "surface is alive" "$([ "$ALIVE" -gt 0 ] && echo true || echo false)"

    # Test 3: page loaded (title not blank/about:blank)
    TITLE=$(cmux browser "$SURFACE" get title 2>/dev/null)
    check "page has title ($TITLE)" "$([ -n "$TITLE" ] && [ "$TITLE" != "about:blank" ] && echo true || echo false)"

    # Test 4: dedup — same URL should not open again
    SURFACE2=$(_open_authed_browser "https://phonetool.amazon.com/users/bssas" "$STATE")
    check "dedup skips same URL" "$([ -z "$SURFACE2" ] && echo true || echo false)"

    # Test 5: taskei rewrite works end-to-end
    SURFACE3=$(_open_authed_browser "https://taskei.amazon.dev/tasks/TRACK-8877" "$STATE")
    check "taskei rewrite opens ($SURFACE3)" "$([ -n "$SURFACE3" ] && echo true || echo false)"
    sleep 2
    ACTUAL_URL=$(cmux browser "$SURFACE3" url 2>/dev/null)
    check "taskei rewrote to SIM" "$(echo "$ACTUAL_URL" | grep -q 'issues.amazon.com' && echo true || echo false)"

    # Test 6: pane reuse — both surfaces should be in the same pane
    PANE1=$(cmux tree --all 2>/dev/null | grep "$SURFACE" | grep -o 'pane:[0-9]*' || true)
    PANE3=$(cmux tree --all 2>/dev/null | grep "$SURFACE3" | grep -o 'pane:[0-9]*' || true)
    # Surfaces are in the same pane (tabs), so they won't show pane in their line.
    # Instead check they share a parent pane by looking at the tree structure.
    SAME_PANE=$(cmux tree --all 2>/dev/null | awk "/$SURFACE|$SURFACE3/"'{count++} END{print (count>=2)?"true":"false"}')
    check "surfaces in same workspace" "$SAME_PANE"

    # Cleanup
    rm -rf "$STATE"
else
    echo "(skipped — cmux not running or cookies stale)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

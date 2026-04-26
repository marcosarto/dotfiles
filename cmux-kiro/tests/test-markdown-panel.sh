#!/bin/bash
# Tests for markdown panel logic in cmux-notify.sh
# Validates: dedup detection, browser pane lookup, surface targeting
# Requires: cmux running (uses cmux tree)

PASS=0 FAIL=0

ok() { echo "✓ $1"; ((PASS++)); }
fail() { echo "✗ $1"; shift; [ -n "$1" ] && echo "  $*"; ((FAIL++)); }

# --- Dedup: [markdown] surface check ---

echo "=== Dedup surface type check ==="

# Simulates the grep pipeline from cmux-notify.sh
check_dedup() {
    local desc="$1" tree_line="$2" expected="$3"
    local result="false"
    echo "$tree_line" | grep "surface:99" | grep -q '\[markdown\]' && result="true"
    if [ "$result" = "$expected" ]; then ok "$desc"; else fail "$desc" "expected=$expected got=$result"; fi
}

check_dedup "markdown surface matches" \
    '    surface surface:99 [markdown] "README.md"' "true"

check_dedup "browser surface does NOT match" \
    '    surface surface:99 [browser] "Example" https://example.com' "false"

check_dedup "terminal surface does NOT match" \
    '    surface surface:99 [terminal] "zsh"' "false"

check_dedup "surface ID not present does NOT match" \
    '    surface surface:100 [markdown] "README.md"' "false"

# --- Browser pane lookup from tree ---

echo ""
echo "=== Browser pane lookup ==="

MOCK_TREE='window window:1
├── workspace workspace:5 "Test WS"
│   ├── pane pane:10 [focused]
│   │   └── surface surface:20 [terminal] "k" [selected] ◀ here
│   └── pane pane:11
│       ├── surface surface:21 [browser] "Example" https://example.com
│       └── surface surface:22 [browser] "Other" https://other.com
├── workspace workspace:6 "Other WS"
│   └── pane pane:12 [focused]
│       └── surface surface:30 [terminal] "zsh" [selected]'

# Find current workspace
CURRENT_WS=$(echo "$MOCK_TREE" | grep -B20 "here" | grep -o 'workspace:[0-9]*' | tail -1)
if [ "$CURRENT_WS" = "workspace:5" ]; then ok "finds current workspace via ◀ here"; else fail "finds current workspace via ◀ here" "got=$CURRENT_WS"; fi

# Find browser surface in current workspace
BROWSER_SURFACE=$(echo "$MOCK_TREE" | grep -A50 "$CURRENT_WS" | awk '/workspace:/ && NR>1{exit} /\[browser\]/{match($0, /surface:[0-9]+/); print substr($0, RSTART, RLENGTH); exit}')
if [ "$BROWSER_SURFACE" = "surface:21" ]; then ok "finds browser surface in current workspace"; else fail "finds browser surface in current workspace" "got=$BROWSER_SURFACE"; fi

# Workspace with no browser surfaces
BROWSER_SURFACE_NONE=$(echo "$MOCK_TREE" | grep -A50 "workspace:6" | awk '/workspace:/ && NR>1{exit} /\[browser\]/{match($0, /surface:[0-9]+/); print substr($0, RSTART, RLENGTH); exit}')
if [ -z "$BROWSER_SURFACE_NONE" ]; then ok "returns empty for workspace with no browser surfaces"; else fail "returns empty for workspace with no browser surfaces" "got=$BROWSER_SURFACE_NONE"; fi

# --- Doesn't bleed across workspaces ---

echo ""
echo "=== Workspace boundary ==="

MOCK_TREE2='window window:1
├── workspace workspace:7 "No Browsers"
│   └── pane pane:13 [focused]
│       └── surface surface:40 [terminal] "k" [selected] ◀ here
└── workspace workspace:8 "Has Browsers"
    ├── pane pane:14 [focused]
    │   └── surface surface:41 [terminal] "zsh" [selected]
    └── pane pane:15
        └── surface surface:42 [browser] "Example" https://example.com'

CURRENT_WS2=$(echo "$MOCK_TREE2" | grep -B20 "here" | grep -o 'workspace:[0-9]*' | tail -1)
BLEED=$(echo "$MOCK_TREE2" | grep -A50 "$CURRENT_WS2" | awk '/workspace:/ && NR>1{exit} /\[browser\]/{match($0, /surface:[0-9]+/); print substr($0, RSTART, RLENGTH); exit}')
if [ -z "$BLEED" ]; then ok "doesn't pick up browser from adjacent workspace"; else fail "doesn't pick up browser from adjacent workspace" "got=$BLEED"; fi

# --- Marker file operations ---

echo ""
echo "=== Marker file ==="

TMPMARKER=$(mktemp)
trap "rm -f $TMPMARKER ${TMPMARKER}.tmp" EXIT

echo "/path/to/file.md	surface:50" > "$TMPMARKER"
echo "/path/to/other.md	surface:51" >> "$TMPMARKER"

# Update existing entry
grep -v "^/path/to/file.md	" "$TMPMARKER" > "${TMPMARKER}.tmp" 2>/dev/null || true
echo "/path/to/file.md	surface:60" >> "${TMPMARKER}.tmp"
mv "${TMPMARKER}.tmp" "$TMPMARKER"

UPDATED=$(grep "^/path/to/file.md	" "$TMPMARKER" | cut -f2)
if [ "$UPDATED" = "surface:60" ]; then ok "marker file updates surface for existing path"; else fail "marker file updates surface for existing path" "got=$UPDATED"; fi

KEPT=$(grep "^/path/to/other.md	" "$TMPMARKER" | cut -f2)
if [ "$KEPT" = "surface:51" ]; then ok "marker file preserves other entries"; else fail "marker file preserves other entries" "got=$KEPT"; fi

LINES=$(wc -l < "$TMPMARKER" | tr -d ' ')
if [ "$LINES" = "2" ]; then ok "marker file has correct line count"; else fail "marker file has correct line count" "got=$LINES"; fi

# --- Integration: browser + markdown in same pane (requires cmux) ---

echo ""
echo "=== Integration: same-pane open ==="

if [ -S "${CMUX_SOCKET_PATH:-/tmp/cmux.sock}" ]; then
    # Find our own surface so we never close it
    MY_SURFACE=$(cmux tree --all 2>/dev/null | grep "here" | grep -o 'surface:[0-9]*')
    BROWSER_RESULT=$(cmux browser open "about:blank" 2>&1)
    BROWSER_SURFACE=$(echo "$BROWSER_RESULT" | grep -o 'surface:[0-9]*')

    if [ -n "$BROWSER_SURFACE" ]; then
        # Find which pane the browser landed in
        sleep 0.3
        BROWSER_PANE=$(cmux tree --all 2>/dev/null | grep "$BROWSER_SURFACE" | grep -oE 'pane:[0-9]+')
        # If grep on the surface line doesn't show pane, walk up the tree
        if [ -z "$BROWSER_PANE" ]; then
            BROWSER_PANE=$(cmux tree --all 2>/dev/null | grep -B5 "$BROWSER_SURFACE" | grep -oE 'pane:[0-9]+' | tail -1)
        fi

        # Open markdown with --surface targeting the browser surface
        TMPMD=$(mktemp /tmp/test-md-panel-XXXX.md)
        echo "# Test" > "$TMPMD"
        MD_RESULT=$(cmux markdown open "$TMPMD" --surface "$BROWSER_SURFACE" 2>&1)
        MD_SURFACE=$(echo "$MD_RESULT" | grep -o 'surface:[0-9]*')

        if [ -n "$MD_SURFACE" ]; then
            sleep 0.3
            MD_PANE=$(cmux tree --all 2>/dev/null | grep -B5 "$MD_SURFACE" | grep -oE 'pane:[0-9]+' | tail -1)

            if [ "$MD_PANE" = "$BROWSER_PANE" ]; then
                ok "markdown opens in same pane as browser (${MD_PANE})"
            else
                fail "markdown opens in same pane as browser" "browser=$BROWSER_PANE markdown=$MD_PANE"
            fi

            # Cleanup (never close our own terminal)
            [ "$MD_SURFACE" != "$MY_SURFACE" ] && cmux close-surface "$MD_SURFACE" 2>/dev/null
        else
            fail "markdown opens in same pane as browser" "failed to open markdown surface"
        fi

        [ "$BROWSER_SURFACE" != "$MY_SURFACE" ] && cmux close-surface "$BROWSER_SURFACE" 2>/dev/null
        rm -f "$TMPMD"
    else
        fail "markdown opens in same pane as browser" "failed to open browser surface"
    fi
else
    echo "  (skipped — cmux not running)"
fi

# --- Summary ---

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

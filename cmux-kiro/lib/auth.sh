#!/bin/bash
# Shared auth functions for cmux browser panels.
# Source this from other scripts: source "$(dirname "$0")/auth.sh"

# Config: ~/.config/cmux-kiro/config (shell vars)
#   CMUX_COOKIE_REFRESH=true     — background cookie refresh daemon
CMUX_COOKIE_REFRESH=true
[ -f "$HOME/.config/cmux-kiro/config" ] && source "$HOME/.config/cmux-kiro/config"

COOKIE_FILE="$HOME/.midway/cookie"

# Internal Amazon domains that need Midway auth
INTERNAL_DOMAINS="amazon\.com|amazon\.dev|a2z\.com|aws\.dev|amazon\.work"

# Extract URLs matching internal domains from text.
# Usage: echo "text" | _extract_internal_urls
_extract_internal_urls() {
    grep -oE "https?://[a-zA-Z0-9._-]+(${INTERNAL_DOMAINS})[^][ \"'<>)}]*" | sort -u
}

# Cross-platform stat: return file mtime as epoch seconds.
_stat_mtime() {
    local f="$1" result
    result=$(stat -f "%m" "$f" 2>/dev/null)
    [[ "$result" =~ ^[0-9]+$ ]] && { echo "$result"; return; }
    result=$(stat -c "%Y" "$f" 2>/dev/null)
    [[ "$result" =~ ^[0-9]+$ ]] && { echo "$result"; return; }
    return 1
}

# Check if midway cookies are fresh enough (< 10 hours old).
_midway_fresh() {
    [ -f "$COOKIE_FILE" ] || return 1
    local mtime now age
    mtime=$(_stat_mtime "$COOKIE_FILE") || return 1
    now=$(date +%s)
    age=$(( now - mtime ))
    [ "$age" -lt 36000 ]
}

# Do the curl SSO flow and return cookies as JSON.
# Usage: _sso_cookies_json "https://phonetool.amazon.com/users/alias"
_sso_cookies_json() {
    local url="$1"
    [ -f "$COOKIE_FILE" ] || return 1
    local tmpjar="/tmp/cmux-auth-$$.txt"
    cp "$COOKIE_FILE" "$tmpjar"
    curl -sS -L -b "$tmpjar" -c "$tmpjar" -o /dev/null "$url" 2>/dev/null || true
    python3 -c "
import json
cookies = []
with open('$tmpjar') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('# '): continue
        if line.startswith('#HttpOnly_'): line = line[10:]
        parts = line.split('\t')
        if len(parts) >= 7:
            cookies.append({
                'name': parts[5], 'value': parts[6],
                'domain': parts[0], 'path': parts[2],
                'secure': parts[3].lower() == 'true'
            })
print(json.dumps(cookies))
" 2>/dev/null
    rm -f "$tmpjar"
}

# Rewrite URLs for sites whose SPAs don't work in WKWebView.
# Taskei's React app does client-side XHR auth that triggers mTLS redirects
# WKWebView can't handle. SIM (issues.amazon.com) is server-rendered and works.
_rewrite_url() {
    local url="$1"
    # taskei.amazon.dev/tasks/TASK-123 → issues.amazon.com/issues/TASK-123
    echo "$url" | sed 's|https://taskei\.amazon\.dev/tasks/|https://issues.amazon.com/issues/|'
}

# Send a raw command to the cmux socket and return the response.
_sock_send() {
    local msg="$1" sock="${2:-${CMUX_SOCKET_PATH:-/tmp/cmux.sock}}"
    echo "$msg" | nc -w 2 -U "$sock" 2>/dev/null
}

# Open a URL in an authed cmux browser panel. Deduplicates by URL.
# Works both locally (real cmux CLI) and remotely (forwarded socket).
# Usage: _open_authed_browser "https://..." "$STATE_DIR" "$SOCKET_PATH"
_open_authed_browser() {
    local url state_dir sock
    url=$(_rewrite_url "$1")
    state_dir="$2"
    sock="${3:-${CMUX_SOCKET_PATH:-/tmp/cmux.sock}}"

    # Deduplicate: skip if this URL already has a live surface
    if [ -n "$state_dir" ] && [ -f "$state_dir/browser_surfaces" ]; then
        local prev_surface
        prev_surface=$(grep "	$url$" "$state_dir/browser_surfaces" 2>/dev/null | tail -1 | cut -f1)
        if [ -n "$prev_surface" ]; then
            if command -v cmux >/dev/null 2>&1 && cmux --version >/dev/null 2>&1 \
                && cmux tree --all 2>/dev/null | grep -q "$prev_surface"; then
                return 0
            elif ! cmux --version >/dev/null 2>&1; then
                # Remote mode (shim or no cmux): assume surface alive
                return 0
            fi
        fi
    fi

    # Skip if midway cookies are expired
    _midway_fresh || return 1

    local cookies_json
    cookies_json=$(_sso_cookies_json "$url") || return 1
    [ -n "$cookies_json" ] && [ "$cookies_json" != "[]" ] || return 1

    local surface
    local _is_remote=false
    command -v cmux >/dev/null 2>&1 && [ "$(cmux supports 2>/dev/null)" != "" ] || _is_remote=true
    # Check if cmux is the real CLI or the Python shim (shim prints "yes" for supports)
    if [ "$_is_remote" = "false" ] && cmux --version >/dev/null 2>&1; then
        _is_remote=false
    else
        _is_remote=true
    fi

    if [ "$_is_remote" = "true" ]; then
        # Remote mode: use raw socket protocol
        # Socket returns "OK <UUID>" for open_browser
        local result uuid
        result=$(_sock_send "open_browser about:blank" "$sock")
        uuid=$(echo "$result" | awk '/^OK /{print $2}')
        [ -n "$uuid" ] || return 1
        surface="$uuid"

        # Inject cookies
        printf '{"id":"1","method":"browser.cookies.set","params":{"surface_id":"%s","cookies":%s}}\n' \
            "$surface" "$cookies_json" | nc -w 2 -U "$sock" >/dev/null 2>&1

        # Navigate to the actual URL (use UUID — browser.navigate accepts it over forwarded socket)
        printf '{"id":"2","method":"browser.navigate","params":{"surface_id":"%s","url":"%s"}}\n' \
            "$surface" "$url" | nc -w 2 -U "$sock" >/dev/null 2>&1
    else
        # Local mode: use real cmux CLI
        local existing_pane
        existing_pane=$(cmux tree --all 2>/dev/null | grep -A50 "${CMUX_WORKSPACE_ID:-$}" \
            | awk '/workspace:/ && NR>1{exit} /\[(browser|markdown)\]/{match($0, /pane:[0-9]+/); if(RSTART) print substr($0, RSTART, RLENGTH); exit}' \
            2>/dev/null)
        if [ -n "$existing_pane" ]; then
            surface=$(cmux browser new "about:blank" --workspace "$CMUX_WORKSPACE_ID" 2>&1 | grep -o 'surface:[0-9]*') || return 1
            cmux move-surface --surface "$surface" --pane "$existing_pane" 2>/dev/null
        else
            surface=$(cmux browser open-split "about:blank" 2>&1 | grep -o 'surface:[0-9]*') || return 1
        fi
        printf '{"id":"1","method":"browser.cookies.set","params":{"surface_id":"%s","cookies":%s}}\n' \
            "$surface" "$cookies_json" | nc -w 2 -U "$sock" >/dev/null 2>&1
        cmux browser "$surface" navigate "$url" >/dev/null 2>&1
    fi

    # Register for cookie refresh
    if [ -n "$state_dir" ]; then
        mkdir -p "$state_dir" 2>/dev/null
        printf '%s\t%s\n' "$surface" "$url" >> "$state_dir/browser_surfaces"
        _stat_mtime "$COOKIE_FILE" > "$state_dir/cookie_mtime" 2>/dev/null
    fi
    echo "$surface"
}

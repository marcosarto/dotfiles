#!/bin/bash
# Open an Amazon internal website in a cmux browser panel with Midway+AEA auth.
# Usage: cmux-auth.sh <url>

set -euo pipefail
source "$(dirname "$0")/auth.sh"

URL="${1:?Usage: cmux-auth.sh <url>}"
WS="${CMUX_WORKSPACE_ID:-}"
STATE_DIR="/tmp/kiro-cmux-$WS"

if [ ! -f "$COOKIE_FILE" ]; then
    echo "Error: $COOKIE_FILE not found. Run 'mwinit' first." >&2
    exit 1
fi

if ! _midway_fresh; then
    echo "Error: Midway cookies are stale. Run 'mwinit' to refresh." >&2
    exit 1
fi

SURFACE=$(_open_authed_browser "$URL" "$STATE_DIR")
echo "Opened $URL in $SURFACE"

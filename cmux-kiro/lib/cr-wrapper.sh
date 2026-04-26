# cr-wrapper.sh — source from .zshrc to detect CRs created outside Kiro
# Wraps the `cr` command to capture CR IDs and pin them to the cmux sidebar.
# No-op outside cmux (checked at call time, not source time).

cr() {
    local output exit_code
    output=$(set -o pipefail; command cr "$@" 2>&1 | tee /dev/stderr)
    exit_code=$?
    if [ -n "$CMUX_SOCKET_PATH" ] && [ -S "$CMUX_SOCKET_PATH" ]; then
        local cr_id
        cr_id=$(echo "$output" | grep -oE 'CR-[0-9]+' | tail -1)
        if [ -n "$cr_id" ]; then
            ~/.cmux-kiro/lib/cr-hook.sh "$cr_id"
        else
            # Clear stale "Creating CR..." pill from pre-cr hook on failure/cancel.
            # Only clear if no real CR is pinned (cr-hook.sh writes cr_id state file).
            local ws="${CMUX_WORKSPACE_ID:-}"
            if [ -n "$ws" ] && [ ! -f "/tmp/kiro-cmux-$ws/cr_id" ]; then
                cmux clear-status cr >/dev/null 2>&1
            fi
        fi
    fi
    return $exit_code
}

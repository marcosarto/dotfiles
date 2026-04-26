#!/bin/bash
# Shared helpers for local .kiro/agents directory resolution

# Echoes the local .kiro/agents path if it exists and differs from global; empty otherwise.
# Usage: local_dir=$(resolve_local_agents_dir "$PWD")
resolve_local_agents_dir() {
    local base="${1:-$PWD}"
    local candidate="$base/.kiro/agents"
    [ -d "$candidate" ] || return 0
    local global_resolved local_resolved
    global_resolved=$(cd "$HOME/.kiro/agents" 2>/dev/null && pwd -P) || { echo "$candidate"; return 0; }
    local_resolved=$(cd "$candidate" 2>/dev/null && pwd -P) || return 0
    if [ "$local_resolved" != "$global_resolved" ]; then
        echo "$candidate"
    fi
}

# Shows "name (local)" for local agents, just "name" for global
# Usage: display=$(agent_display_name "/path/to/agent.json" "$local_dir")
agent_display_name() {
    local filepath="$1" local_dir="$2"
    local bn="${filepath##*/}"
    bn="${bn%.json}"
    if [ -n "$local_dir" ] && [[ "$filepath" == "$local_dir"/* ]]; then
        echo "$bn (local)"
    else
        echo "$bn"
    fi
}

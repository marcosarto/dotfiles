---
inclusion: always
---
# cmux + Kiro Integration

You are running inside [cmux](https://cmux.dev), a terminal multiplexer with a sidebar, browser panels, and markdown viewers. Hooks automatically update the sidebar with your status, tool calls, and task detection.

## Browser Panels for Internal Sites

Open authenticated internal sites in cmux browser panels:

```bash
~/.cmux-kiro/lib/auth-open.sh <url>
```

When to open a browser panel (use judgment):
- Showing a code review, task, or wiki page the user should review
- Displaying someone's phonetool profile when discussing team/org info
- Showing a dashboard or monitoring page relevant to the conversation
- Do NOT open panels just because a URL appeared in tool output — only when the user would benefit from seeing it

Example:
```bash
~/.cmux-kiro/lib/auth-open.sh https://phonetool.amazon.com/users/alias
```

Authentication is handled automatically (SSO cookie injection). A background daemon refreshes cookies after `mwinit`.

## Sidebar Task & CR Pins

Tasks and CRs are automatically detected and pinned to the sidebar by hooks. Do NOT manually set task or CR pills — the hooks handle it.

If you need to pin a task that wasn't auto-detected, use the raw socket (the `cmux` CLI does not support `--url`):

```bash
echo "set_status task SIM-12345 --icon=tag --color=#64d2ff --url=https://issues.amazon.com/issues/SIM-12345 --tab=$CMUX_WORKSPACE_ID" | nc -w 1 -U "${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
```

Do NOT manually set CR pills — the CRUX hook chain handles CR detection automatically.

## Available cmux Commands

```bash
# Sidebar status pills
cmux set-status kiro "working" --icon brain --color "#ff9500"

# Sidebar log
cmux log --level info --source kiro "message"

# Desktop notification
cmux notify --title "Kiro" --subtitle "project" --body "done"

# Progress bar
cmux set-progress 0.5 --label "Running tests"
cmux clear-progress

# Markdown panel (live-reloads on file change)
cmux markdown open plan.md

# Browser panel
cmux browser open "https://example.com"
```

---
inclusion: always
---
# cmux + Kiro Integration

This repo provides hooks that integrate Kiro CLI with [cmux](https://cmux.dev), a terminal multiplexer with a rich sidebar, browser panels, markdown viewers, and a socket-based automation API.

## Architecture

cmux is a macOS app that wraps terminal sessions (Kiro, Claude Code, etc.) in workspaces with a sidebar UI. It exposes a Unix socket at `/tmp/cmux.sock` for automation. Kiro hooks fire shell scripts on agent lifecycle events, and those scripts talk to cmux via the socket to update the UI.

```
User prompt → Kiro CLI → Hook events → cmux-notify.sh → cmux socket → Sidebar UI
```

### Environment Variables (set by cmux)

- `CMUX_WORKSPACE_ID` — current workspace (tab) ID
- `CMUX_TAB_ID` — alias for workspace ID in v1 commands
- `CMUX_PANEL_ID` — current terminal surface ID
- `CMUX_SOCKET_PATH` — socket path (default `/tmp/cmux.sock`)
- `CMUX_SURFACE_ID` — current surface handle

### Hook Events

| Event | When | What we do |
|---|---|---|
| `agentSpawn` | Session starts | Set workspace title with ◆ icon, create kiro pill ("ready", grey/✓), clear stale activity pill, report git branch |
| `userPromptSubmit` | User sends prompt | Log prompt, generate AI title (background), detect task IDs, reset turn tracking, clear stale notifications (workspace-scoped), fire background activity pill kask call (no placeholder — pill appears when AI returns), set kiro pill "working" (orange/brain) |
| `preToolUse` | Before tool runs | Update kiro pill with human-readable tool description + contextual icon (grey) via `_tool_description()` + `_tool_icon()` |
| `postToolUse` | After tool runs | On success: kiro pill shows past-tense description with checkmark (grey). On failure: kiro pill "error" (red/⚠️). Track tools/errors, detect CR IDs, mid-turn title refinement (first `ReadInternalWebsites` only), refresh git |
| `stop` | Turn complete | Update activity pill with final state: success (green/👍), waiting (purple/💬), or errors (red/⚠️). Clear kiro pill. AI notification, refresh git |

## Key Files

| File | Purpose |
|---|---|
| `hooks/cmux-notify.sh` | Main hook script — handles all events, sidebar updates, turn tracking |
| `hooks/cmux-title.sh` | Background title generation + task detection via `kask` with `cmux-titler` agent |
| `hooks/cmux-summarize-notify.sh` | Background notification summary via `kask` with `cmux-notifier` agent. Also handles `--activity` mode for turn objective pill via `cmux-activity` agent |
| `agents/cmux.json` | Agent config — hooks, tools, MCP servers |
| `agents/cmux-titler.json` | Minimal kimi-k2.5 agent for title generation (no tools, constrained prompt) |
| `agents/cmux-notifier.json` | Minimal kimi-k2.5 agent for turn summarization into JSON notification (no tools, constrained prompt). Symlinked to `~/.kiro/agents/` |
| `agents/cmux-activity.json` | Minimal kimi-k2.5 agent for activity pill summaries (no tools, constrained prompt). Symlinked to `~/.kiro/agents/` |
| `lib/auth.sh` | Shared auth library — URL detection, SSO cookie flow, deduped browser opening |
| `lib/auth-open.sh` | Browser panel opener — auth + navigate (uses `lib/auth.sh`) |
| `lib/cookie-refresh.sh` | Background daemon: polls `~/.midway/cookie` mtime, re-injects cookies into tracked browser surfaces on change |
| `lib/cr-hook.sh` | Reusable CR → sidebar pill updater, called by `cr-wrapper.sh` and `hooks/pre-cr` |
| `lib/cr-wrapper.sh` | Shell function wrapper for `cr` CLI — sourced from `.zshrc`, captures CR IDs from any pane |
| `hooks/pre-cr` | CRUX pre-CR hook — shows "creating..." feedback in sidebar before CR is created |
| `tests/test-titler.sh` | Smoke tests for title generation |
| `tests/test-notifier.sh` | Smoke tests for notification JSON generation |
| `tests/test-activity.sh` | Smoke tests for activity pill summaries |
| `tests/test-activity-leak.sh` | Tests cross-workspace activity leak via shared kask daemon conversation history |
| `tests/test-process-leak.sh` | Smoke test for kask process leak — verifies broken ACP doesn't orphan processes |
| `tests/test-daemon-recovery.sh` | Tests kask daemon self-healing — kills ACP subprocess mid-session, verifies next call recovers |
| `tests/test-user-title.sh` | Tests for user-set workspace title preservation (markers, mid-session rename detection) |
| `tests/test-shim-scoping.sh` | Tests for remote shim workspace scoping (--tab injection, notify_target defaulting) |
| `tests/test-remote-setup.sh` | Tests setup parity — validates all three setup scripts install the same agents, steering files, etc. |
| `tests/test-event-formats.sh` | Tests postToolUse event parsing across old CLI and new TUI payload formats |
| `docs/warm-acp-client.md` | Documentation for kask (warm ACP client) |
| `bin/kiro-acp-client.py` | kask — warm ACP client script, installed to `~/bin/` by setup |
| `bin/kiro-cmux` | CLI dispatcher — `kiro-cmux setup`, `update`, `doctor`, `sync`, `test`, `--version` |
| `bin/cmux-ssh` | SSH wrapper — cleans stale sockets, reverse-forwards cmux socket, exports `CMUX_*` env vars, shows/clears host pill, installs ghostty terminfo on remote |
| `agents/fast.json` | Minimal kimi-k2.5 agent for kask (no tools, no MCP) |
| `lib/update.sh` | Shared update library — version check, git pull, throttling, agent re-linking |
| `update.sh` | Manual update command — interactive version check and pull |
| `agents/cmux.json.template` | Agent config template — `__INSTALL_DIR__` and `__HOME__` placeholders expanded by `setup.sh` |
| `VERSION` | Current version number (semver), bumped on releases |
| `lib/remote/cmux-shim` | Python3 replacement for native `cmux` CLI — translates CLI args to v1 socket protocol |
| `lib/remote/nc-shim` | Python3 replacement for `nc -U` — reads stdin, sends to unix socket, prints response |
| `lib/remote/setup-remote.sh` | Standalone remote setup — run directly on the remote host if preferred |
| `lib/remote/setup-remote-push.sh` | One-command setup from laptop — rsyncs repo, installs shims, injects hooks, links agents, installs kask |

## cmux CLI Commands We Use

```bash
# Sidebar status pills (key, value, icon, color)
cmux set-status kiro "working" --icon brain --color "#ff9500"     # thinking (orange)
cmux set-status kiro "Reading config.ts" --icon doc.text --color "#aeaeb2"  # tool in-progress (grey)
cmux set-status kiro "Read config.ts" --icon checkmark --color "#aeaeb2"    # tool completed (grey)
cmux set-status kiro "waiting" --icon bubble.left.fill --color "#bf5af2"  # needs input (purple)
cmux set-status kiro "Finished" --icon checkmark --color "#aeaeb2"    # done (grey)
cmux set-status kiro "error" --icon exclamationmark.triangle --color "#ff453a"  # error (red)
cmux set-status activity "Implementing auth refresh" --icon quote.bubble --color "#ff9500"  # turn objective (orange)
cmux set-status activity "Implementing auth refresh" --icon hand.thumbsup --color "#30d158"  # turn complete (green)
cmux set-status task "SIM-12345" --icon tag --color "#64d2ff"
cmux set-status cr "CR-67890" --icon arrow.triangle.pull --color "#0a84ff"

# Workspace title
cmux workspace-action --workspace "$WS" --action rename --title "◆ My Title"

# Sidebar log
cmux log --level info --source kiro "message"    # levels: info, success, error, progress

# Desktop notification
cmux notify --title "Kiro" --subtitle "project" --body "Response complete"

# Git branch in sidebar
echo "report_git_branch main --status=dirty --tab=$TAB --panel=$PANEL" | nc -w 1 -U /tmp/cmux.sock

# Progress bar
cmux set-progress 0.5 --label "Running tests"
cmux clear-progress

# Markdown panel (live-reloads on file change)
cmux markdown open plan.md

# Browser panel
cmux browser open "https://example.com"
```

### Status Pill Icons

Icons use SF Symbols, emoji, or text:
- SF Symbol: `bolt`, `checkmark`, `hammer`, `tag`, `arrow.triangle.pull`
- Emoji: `emoji:⚡`
- Text badge: `text:K`

Tool-contextual icons (kiro pill, in-progress state):
- `doc.text` — fs_read, read, glob
- `pencil` — fs_write, write
- `terminal` — execute_bash, shell
- `magnifyingglass` — InternalSearch, web_search, code, grep, InternalCodeSearch, WorkspaceSearch, lusca
- `globe` — ReadInternalWebsites, web_fetch
- `cloud` — use_aws, aws
- `doc.on.doc` — QuipEditor
- `arrow.triangle.branch` — use_subagent, subagent
- `brain` — thinking
- `checklist` — todo_list
- `book` — knowledge, aws-knowledge-mcp
- `info.circle` — introspect, report_issue
- `arrow.triangle.pull` — CRRevisionCreator, github
- `hammer` — BrazilBuild*, BrazilWorkspace
- `arrow.triangle.capsulepath` — GetPipeline*
- `tag` — Taskei*, TicketingReadActions
- `testtube.2` — ReadRemoteTestRun
- `sparkles` — SkillsTool
- `chart.bar` — pippin
- `bubble.left.and.bubble.right` — slack
- `envelope` — outlook
- `exclamationmark.triangle` — coe
- `bolt.fill` — unknown/fallback

## cmux Socket Control Modes

cmux exposes a Unix domain socket (not a network socket — purely local, no port, no network exposure) for automation. The socket file lives at `/tmp/cmux.sock` (or a user-scoped path in `~/Library/Application Support/cmux/`). Settings (⌘,) → Socket Control Mode controls who can connect.

Five modes exist (from [SocketControlSettings.swift](https://github.com/manaflow-ai/cmux/blob/main/Sources/SocketControlSettings.swift)):

| Mode | Description | Socket permissions | Auth |
|---|---|---|---|
| **Off** | Socket disabled entirely | n/a | n/a |
| **cmux processes only** | Only processes descended from cmux terminals can connect (ancestry check) | `0o600` (owner only) | No |
| **Automation mode** | Any process running as the current macOS user can connect (no ancestry check) | `0o600` (owner only) | No |
| **Password mode** | Requires password auth. Password stored in `~/Library/Application Support/cmux/socket-control-password` or `CMUX_SOCKET_PASSWORD` env var | `0o600` (owner only) | Yes |
| **Full open access** | Any local process/user, no auth. Sets `0o666` (world-readable/writable). Source code labels this "Unsafe." | `0o666` | No |

**kiro-cmux only needs "cmux processes only" (the default).** All our hooks run as child processes of cmux terminals — including `& disown`'d background processes (title generation, notifications, cookie refresh), which retain their process ancestry even after detachment. Tested and confirmed working.

Legacy env values: `CMUX_SOCKET_MODE=notifications` maps to `automation`, `full` maps to `allowAll`.

## cmux Socket Protocol

v1 (line-oriented): `command args --flag=value\n` → `OK` or error
v2 (JSON): `{"id":"1","method":"workspace.list","params":{}}` → `{"id":"1","ok":true,"result":{...}}`

Cookie injection for browser auth uses v2:
```json
{"id":"1","method":"browser.cookies.set","params":{"surface_id":"surface:N","cookies":[...]}}
```

## Browser Auth for Internal Sites

cmux's browser uses WKWebView which can't do mTLS or load the AEA extension. `lib/auth.sh` provides shared auth functions used by hooks and scripts: URL detection, SSO cookie flow via curl, and deduped browser opening.

Internal URLs can be opened in authed browser panels:
- Kiro calls `./lib/auth-open.sh <url>` via `execute_bash` when it wants to show the user something
- Manual: `./lib/auth-open.sh <url>` for explicit opens

When to open a browser panel (Kiro should use judgment):
- Showing a code review, task, or wiki page the user should review
- Displaying someone's phonetool profile when discussing team/org info
- Showing a dashboard or monitoring page relevant to the conversation
- Do NOT open panels just because a URL appeared in tool output — only when the user would benefit from seeing it

```bash
./lib/auth-open.sh https://phonetool.amazon.com/users/alias
```

Flow: curl does full SSO chain (site → midway-auth SSO → site?id_token → site with session cookie) → inject all cookies into browser → navigate. All opens are deduped — if a URL already has a live browser surface, it's skipped.

A background daemon (`lib/cookie-refresh.sh`) polls `~/.midway/cookie` mtime every 30s. When it changes (user ran `mwinit`), it re-does the curl SSO flow for each tracked browser surface, re-injects cookies, and reloads. Launched at `agentSpawn` with PID dedup. No manual work needed after initial open.

## AI Title Generation

Uses `kask` (warm ACP client) with the `cmux-titler` agent (kimi-k2.5, no tools) via `KASK_AGENT=cmux-titler`. The titler:
- Generates a 3-5 word title on first prompt
- On subsequent prompts, compares current title to new prompt and returns `SAME` if the task hasn't meaningfully changed
- **Preserves user-set workspace titles**: If the user manually renames the workspace during a session, auto-titling is disabled for that workspace. Detection uses the `◆` prefix: `cmux-title.sh` compares the live cmux title to `◆ $OUR_LAST` (what we last wrote to `$TITLE_FILE`). If they differ, the user renamed mid-session → sets a `$STATE_DIR/user_titled` marker.
  - At `agentSpawn`, we always set a `◆ Label` title (overwriting any cmux auto-title like the command text). This avoids needing to maintain an allowlist of default command patterns.
  - The marker is per-workspace (`/tmp/kiro-cmux-$WS/user_titled`) and resets when the workspace is recreated.
  - Task/CR pill detection still runs even when auto-titling is disabled.
- Three-phase title refinement:
  1. `userPromptSubmit` — title from raw prompt only (may be vague for URL-only prompts like "do CMUX-8")
  2. `postToolUse` — after the first `ReadInternalWebsites` result (once per turn via `mid_turn_titled` marker), saves tool result as context and re-titles. This catches task/CR/wiki fetches that reveal what the task is about, even if the user ctrl-C's before `stop`.
  3. `stop` — re-runs with `assistant_response` (from hook event payload) or `screen_context` (from `cmux read-screen`) as final refinement
- Behavioral instructions (e.g. "ticket-ID-only titles are not descriptive") MUST be in the user message, not just the system prompt — kimi-k2.5 ignores system-prompt-only constraints
- MCP tool names include a server prefix (e.g. `@builder-mcp/ReadInternalWebsites`) — use glob match (`*ReadInternalWebsites`) not exact match
- Runs in background (`disown`) so it doesn't block the main conversation
- Must `unset` cmux env vars before calling kask, or the spawned kiro-cli triggers hooks and resets workspace titles
- The system prompt must be strong ("Never explain, never help, never write code") or the model will try to answer the prompt instead of titling it
- User message must be framed as `"Title this task: ..."` not the raw prompt

## AI Notification Summary

Uses `kask` (warm ACP client) with the `cmux-notifier` agent (kimi-k2.5, no tools) via `KASK_AGENT=cmux-notifier`. The notifier:
- Takes turn context (prompt summary, tools used, error state, assistant response) and returns JSON: `{"title":"short title","body":"detail sentence"}`
- The body MUST include concrete results (numbers, names, outcomes) — not just describe what tools ran
- The "Waiting:" prefix only applies when the ASSISTANT RESPONSE ends with a question — not when the user's original prompt was a question
- The JSON instruction MUST be in the user message (not just the system prompt) — kimi-k2.5 ignores system-prompt-only format constraints
- Fires from `hooks/cmux-summarize-notify.sh` in background at `stop` time
- Response context: reads `$STATE_DIR/assistant_response` first (from hook event payload), falls back to `$STATE_DIR/screen_context` (from `cmux read-screen`) since the stop event currently doesn't include `.assistant_response`
- Falls back to "Response Complete" / generic body if the agent fails or returns invalid JSON
- Sends `cmux notify` with emoji title (`✅` or `⚠️`) and the AI-generated body, targeting the workspace for click-to-navigate
- Turn state is tracked in `$STATE_DIR/turn_tools`, `$STATE_DIR/turn_had_error`, `$STATE_DIR/last_prompt`
- Turn state is reset at `userPromptSubmit` so each turn gets a fresh summary
- Output may be wrapped in markdown code fences (` ```json `) — strip before parsing
- Agent config must be symlinked to `~/.kiro/agents/` for kiro-cli to discover it

## AI Activity Summary

Uses `kask` (warm ACP client) with the `cmux-activity` agent (kimi-k2.5, no tools) via `KASK_AGENT=cmux-activity`. Separate agent from notifier to avoid blocking desktop notifications. The activity agent:
- Takes the user's prompt and returns JSON: `{"activity":"present tense description, max 30 chars"}`
- Fires from `hooks/cmux-summarize-notify.sh --activity` in background at `userPromptSubmit` time
- No placeholder shown — activity pill appears only when the AI response arrives
- Activity text is prefixed with "Working: " when displayed in the pill
- Saved to `$STATE_DIR/last_activity` for reuse at `stop` (final state icon/color update)
- At `stop`, the activity pill is updated (not cleared) with final state: success (green/👍), waiting (purple/💬), or errors (red/⚠️)
- Race condition guard: `$STATE_DIR/activity_active` marker is set at `userPromptSubmit` and removed at `stop`. The background script checks this before writing — if gone, the turn ended and the script exits silently
- **Cross-workspace isolation**: The kask daemon shares a single ACP session (conversation history) across all workspaces. The activity prompt includes `"Each request is independent. Do NOT reference any previous requests or responses"` to prevent the model from leaking one workspace's topic into another's activity pill. For vague confirmation prompts ("yes", "ok") with no `prev_activity`, the model returns empty and the pill is not updated.
- Output may be wrapped in markdown code fences — strip before parsing
- Agent config must be symlinked to `~/.kiro/agents/` for kiro-cli to discover it

## kask (Warm ACP Client)

See `docs/warm-acp-client.md` for full details. Key points for hook scripts:
| `lib/update.sh` | Shared update library — version check, git pull, throttling, agent re-linking |
| `update.sh` | Manual update command — interactive version check and pull |
| `agents/cmux.json.template` | Agent config template — `__INSTALL_DIR__` and `__HOME__` placeholders expanded by `setup.sh` |
| `VERSION` | Current version number (semver), bumped on releases |
| `tests/test-process-leak.sh` | Smoke test for kask process leak — verifies broken ACP doesn't orphan processes |
| `tests/test-daemon-recovery.sh` | Tests kask daemon self-healing — kills ACP subprocess mid-session, verifies next call recovers |
- Use `KASK_AGENT=<name> python3 ~/bin/kiro-acp-client.py "<msg>"` (shell aliases don't work in scripts)
- Supports `KASK_AGENT` env var to override the default `fast` agent
- ~5-6s cold start (vs ~15s for `kiro-cli chat --no-interactive`) due to no MCP loading; warm daemon calls are faster
- Output may include markdown code fences — always strip before parsing
- The ACP subprocess (`kiro-cli`) is spawned with `start_new_session=True` so the entire process tree (kiro-cli → aim sandbox → kiro-cli → kiro-cli-chat) lives in its own process group
- `close()` uses `os.killpg()` to SIGTERM the whole process group — `proc.terminate()` alone only kills the direct child, leaving grandchildren orphaned on macOS
- If `_handshake()` fails (e.g. broken ACP subcommand), the constructor calls `self.close()` before re-raising to avoid leaking the subprocess
- The daemon loop catches `KiroAcpClient()` construction failures separately — if the constructor throws, `client` is never assigned, so the outer `if client: client.close()` would be a no-op and leak the process
- `ensure_daemon()` uses `fcntl.flock()` on a per-agent lock file to prevent race conditions where multiple concurrent callers spawn duplicate daemons. The lock is only held during the check+spawn sequence and auto-releases if the process crashes

### Daemon Self-Healing

When the ACP subprocess dies mid-session (e.g. `kiro-cli` crashes), the daemon recovers automatically:

1. **Fast detection**: `wait_response()` polls every 500ms checking `proc.poll()` and a `_dead` flag (set when the reader thread sees stdout close). Dead process detected in under a second.
2. **Loud failure**: `prompt()` raises on timeout or dead process (instead of silently returning empty). The daemon catches it, closes the dead client, sends `ERROR:` to the caller.
3. **Caller-side recovery**: When the caller gets `ERROR:`, it kills the broken daemon entirely (`SIGKILL` via `_stop_daemon()`), spawns a fresh one via `ensure_daemon()`, and retries. Full recovery in ~4 seconds.

### Timeouts

| Path | Timeout | Notes |
|---|---|---|
| Daemon → `prompt()` | 15s/10s | 15s for first prompt after cold start (backend may be slow loading agent); 10s for subsequent warm prompts |
| Caller → daemon socket (`send_to_daemon`) | 20s | 15s prompt + overhead |
| ACP handshake (`initialize` + `session/new`) | 10s each | Cold start is ~5-6s, 10s gives headroom |
| REPL / cold-start fallback `prompt()` | 30s | Default for non-daemon paths |

### `~/bin/` Copy Gotcha

`setup.sh` **copies** `bin/kiro-acp-client.py` to `~/bin/` — it's not a symlink. When developing, edits to the repo copy don't take effect until you `cp bin/kiro-acp-client.py ~/bin/`. In dev mode (`~/.cmux-kiro` symlinked to workspace), the hook scripts use `~/bin/kiro-acp-client.py` (the copy), not the repo version.

## Task/CR Detection

Task and CR detection use separate mechanisms:

**Task IDs** are extracted by the `cmux-titler` agent in `hooks/cmux-title.sh`. The titler's JSON response includes a `.task` field from the prompt context. Task pills link to `issues.amazon.com` and are cleared when the titler detects a task change.

**CR IDs** are detected from actual CR creation events only (not conversation text):
1. **User runs `cr` in any pane** → `lib/cr-wrapper.sh` (shell function sourced from `.zshrc`) captures `cr` output, extracts `CR-XXXXXX`, calls `lib/cr-hook.sh` to update the sidebar pill.
2. **Kiro runs `cr` via `execute_bash`/`shell`** → `postToolUse` hook in `cmux-notify.sh` first checks that the command contains `\bcr\b` (word boundary match on `.tool_input.command`), then scans the full tool response for `CR-XXXXXX` via `_tool_response_text()` and calls `lib/cr-hook.sh`. This prevents false positives from commands like `git log` whose output may contain `CR-` strings. Must read from the full event JSON (via `_tool_response_text`), not the truncated `TOOL_RESULT` variable (200 chars — too short for `cr` output).
3. **CRUX pre-cr hook** (`hooks/pre-cr`) shows "Creating CR..." feedback in the sidebar *before* `cr` finishes, but does not set the CR ID (it doesn't exist yet).

Detected IDs are persisted in `/tmp/kiro-cmux-$WS/` (`task_id`, `cr_id`) so pills only update on change.

## SSH Remote Mode

kiro-cmux works over SSH — Kiro runs on a remote Linux host (e.g. cloud desktop), sidebar/notifications/titles show on the local laptop's cmux.

```
Laptop (cmux + socket) ←── SSH reverse tunnel ──→ Cloud Desktop (kiro-cli + hooks + shims)
```

### How It Works

1. `cmux-ssh` reverse-forwards the laptop's cmux socket to `/tmp/cmux.sock` on the remote
2. Python3 shims replace the native `cmux` CLI and `nc` (neither available on Linux)
3. Hooks fire on the remote, talk to shims, shims send commands through the forwarded socket back to the laptop
4. `CMUX_*` env vars are exported by `cmux-ssh` so hooks know which workspace to update

### SSH Remote Files

| File | Purpose |
|---|---|
| `bin/cmux-ssh` | SSH wrapper — cleans stale sockets, reverse-forwards cmux socket, exports `CMUX_*` env vars, shows/clears host pill, installs ghostty terminfo on remote |
| `lib/remote/cmux-shim` | Python3 replacement for native `cmux` CLI — translates CLI args to v1/v2 socket protocol, special handling for `notify`, `workspace-action` (v2 JSON), `browser open` |
| `lib/remote/nc-shim` | Python3 replacement for `nc -U` — reads stdin, sends to unix socket, prints response. Handles both v1 and v2 protocol |
| `lib/remote/setup-remote.sh` | Standalone remote setup — run directly on the remote host if preferred |
| `lib/remote/setup-remote-push.sh` | One-command setup from laptop — rsyncs repo, installs shims, injects hooks, links agents, installs kask (used by `kiro-cmux setup-remote`) |

### SSH Setup

```bash
# One-time setup from laptop (inside cmux):
kiro-cmux setup-remote <hostname>

# Every session:
kiro-cmux ssh <hostname>
# Then on remote:
k
```

Alternatively, set up directly on the remote:
```bash
git clone ssh://git.amazon.com/pkg/AmznCmuxKiroTools ~/.cmux-kiro
~/.cmux-kiro/lib/remote/setup-remote.sh
```

### SSH Sidebar Indicator

At `agentSpawn`, if `$SSH_CONNECTION` is set, a grey hostname pill is shown:
```bash
cmux set-status host "$(hostname -s)" --icon desktopcomputer --color "#8e8e93"
```

The pill is also managed by `cmux-ssh` itself: set on connect (before Kiro starts), cleared on disconnect.

### SSH-Specific Gotchas

1. **Stale sockets**: When SSH disconnects, `/tmp/cmux.sock` stays on the remote. Next connection fails with "remote port forwarding failed". `cmux-ssh` handles this by removing the stale socket before connecting and using `StreamLocalBindUnlink=yes`.
2. **PATH in background scripts**: On Linux, `kiro-cli` installs to `~/.local/bin` (added by `.zshrc`). Background processes (`& disown`) don't source `.zshrc`, so kask can't find `kiro-cli`. Fixed by adding `export PATH="$HOME/.local/bin:$HOME/bin:$PATH"` at the top of `cmux-title.sh` and `cmux-summarize-notify.sh`.
3. **`CMUX_WORKSPACE_ID` must be correct**: The title script uses `WS` to query `workspace.list` and detect user-set titles. If `CMUX_WORKSPACE_ID` is empty or wrong (e.g. plain `ssh` without `cmux-ssh`), the mid-session rename detection can't find the workspace and may falsely set the `user_titled` marker, blocking all auto-titling.
4. **cmux CLI → socket command mapping**: The native CLI uses hyphens (`set-status`), the socket uses underscores (`set_status`). The shim handles this translation. The `notify` command has a completely different syntax: CLI uses `--title`/`--body` flags, socket uses `title|subtitle|body` pipe format.
5. **Markdown panels don't work remotely**: `cmux markdown open` requires a local file path. The shim prints a warning and exits 0.
6. **Browser panels DO work remotely**: `cmux browser open <url>` goes through the socket — cmux on the laptop opens the browser panel locally.
7. **Shim workspace scoping**: The native `cmux` CLI defaults `--workspace` to `$CMUX_WORKSPACE_ID`, but the remote shim must replicate this. Without it, multiple SSH workspaces sharing one forwarded socket send commands to the wrong workspace. The shim reads `CMUX_WORKSPACE_ID`/`CMUX_TAB_ID`/`CMUX_SURFACE_ID` from env and injects `--tab` for scoped commands (`set_status`, `clear_status`, `log`, `set_progress`, `clear_progress`, `read_screen`) and defaults workspace/surface for `notify_target`. Background scripts that `unset` env vars must re-export them before calling `cmux`.

## Common Gotchas

1. **Hook exit codes matter**: Exit code 1 = warning shown to user. Exit code 2 (preToolUse) = blocks the tool. Always end scripts with `exit 0`.
2. **grep in hooks**: `grep -q` returns exit code 1 on no match, which becomes the script's exit code if it's the last command. Guard with `|| true` or ensure `exit 0` at end.
3. **ANSI codes in kiro-cli output**: `kiro-cli chat --no-interactive` output contains ANSI escape codes and bell characters. Strip with: `sed $'s/\x1b\[[0-9;]*m//g; s/\x07//g'`
4. **cmux socket availability**: Always check `[ -S /tmp/cmux.sock ]` before running cmux commands. The socket doesn't exist outside cmux.
5. **Midway cookie format**: Netscape tab-separated format. Lines starting with `#HttpOnly_` have the prefix stripped before parsing. Some lines are comments (`# Netscape`, `# https`).
6. **Title generation timing**: Only fires on first prompt per workspace (marker file), then on every subsequent prompt to check for task changes. Uses `/tmp/kiro-title-$WS` to track current title.
7. **Markdown panel dedup**: Tracks opened files in `/tmp/kiro-md-opened-$WS` to avoid opening duplicate panels. The panel auto-reloads on file changes.
8. **Background subagent hooks**: Background scripts that call `kiro-cli` or `kask` MUST `unset` cmux env vars (`CMUX_WORKSPACE_ID`, `CMUX_TAB_ID`, `CMUX_PANEL_ID`, `CMUX_SOCKET_PATH`, `CMUX_SURFACE_ID`) or the spawned session triggers hooks and resets workspace titles.
9. **Background process detachment**: Use `cmd </dev/null >/dev/null 2>&1 & disown` to fully detach background processes from hook scripts. `nohup` alone is not sufficient — Kiro's hook runner waits for the process group.
10. **Shell aliases in scripts**: `kask` is a zsh alias — use `python3 ~/bin/kiro-acp-client.py` in scripts instead.
11. **kask output format**: kask may wrap output in markdown code fences (` ```json `). Always strip with `sed 's/```json//; s/```//'` before parsing.
12. **Agent discovery**: Agent JSON configs must be in `~/.kiro/agents/` for `kiro-cli` to find them. Symlink from repo: `ln -s /path/to/agent.json ~/.kiro/agents/`
13. **xargs and quotes**: Never use `xargs` to trim whitespace in hook scripts — apostrophes in AI output cause `xargs: unterminated quote`. Use `sed 's/^[[:space:]]*//; s/[[:space:]]*$//'` instead.
14. **Workspace ID format**: `$CMUX_WORKSPACE_ID` is a UUID but `workspace.list` results have both `.id` (UUID) and `.ref` (`workspace:N`). Always match with `select(.ref == $ws or .id == $ws)` to handle both.
15. **Setup parity across local and remote**: Three setup scripts must stay in sync: `setup.sh` (laptop), `lib/remote/setup-remote.sh` (standalone remote), and `lib/remote/setup-remote-push.sh` (push from laptop). When adding a new agent config, steering file, or install step to one, add it to all three. `tests/test-remote-setup.sh` validates parity — run it after setup changes. Common things that get missed: agent JSON symlinks, steering file links, shell aliases, `~/bin/` tool installs.
16. **TUI vs CLI event format**: The old CLI (`chat-cli` crate) and new TUI (`agent` crate) use different `postToolUse` payload structures for `.tool_response`. Old CLI: `{"success": true, "result": [...]}`. New TUI: `{"items": [{"Json": {...}}, {"Text": "..."}]}`. No `.success` field in the new TUI. Always use `_tool_response_text()` to extract tool output — never read `.tool_response.result` or `.tool_response.items` directly. The helper handles both formats. `tests/test-event-formats.sh` validates this.

## Debugging Kiro CLI Internals

The Kiro CLI source is at [github.com/kiro-team/kiro-cli](https://github.com/kiro-team/kiro-cli). Use the `gh` CLI to search and read source files when debugging hook integration issues — especially when kiro-cli changes break our hooks.

```bash
# Search for a symbol or string across the repo
gh search code "tool_response" --repo kiro-team/kiro-cli --limit 20

# Read a specific file
gh api repos/kiro-team/kiro-cli/contents/PATH --jq '.content' | base64 -d

# Read the official hooks documentation
gh api repos/kiro-team/kiro-cli/contents/docs/hooks.md --jq '.content' | base64 -d
```

Key source paths:
| Path | What it contains |
|---|---|
| `docs/hooks.md` | Official hook event documentation |
| `crates/chat-cli/src/cli/chat/mod.rs` | Old CLI tool execution + hook dispatch (wraps response in `{success, result}`) |
| `crates/chat-cli/src/cli/chat/cli/hooks.rs` | Old CLI hook runner (ToolContext, payload construction) |
| `crates/agent/src/agent/mod.rs` | New TUI/agent tool execution + hook dispatch (serializes ToolExecutionOutput directly) |
| `crates/agent/src/agent/task_executor/mod.rs` | New TUI hook runner (ToolContext, payload construction) |
| `crates/agent/src/agent/tools/mod.rs` | `ToolExecutionOutput` / `ToolExecutionOutputItem` types (defines the `{items: [{Json, Text}]}` format) |
| `crates/agent/src/agent/agent_loop/types.rs` | `ToolResultContentBlock` types (Text, Json, Image) |

Two separate code paths exist for hooks:
- **Old CLI** (`chat-cli` crate): `mod.rs` wraps tool output in `{"success": true, "result": content}` before passing to `cli/hooks.rs`
- **New TUI** (`agent` crate): `mod.rs` serializes `ToolExecutionOutput` directly via `serde_json::to_value()`, passes to `task_executor/mod.rs`

When kiro-cli updates break our hooks, the pattern is: capture the raw event JSON (write `$EVENT` to a debug file in `postToolUse`), compare against what the source says, and update `_tool_response_text()` or other helpers accordingly.

## Taskei

Project board: [taskei.amazon.dev/rooms/c10b1c24-23a8-49f1-b8e5-f396cddf1e55](https://taskei.amazon.dev/rooms/c10b1c24-23a8-49f1-b8e5-f396cddf1e55/board)

Use the Taskei MCP (available via `amzn-builder` subagent) to create, update, and query tasks programmatically. Prefer this over manual creation.

## Git Commit & Push Policy

**MUST NOT** run `git commit` or `git push` unless the user gives explicit instruction to do so. Never commit or push automatically — always wait for the user to say to commit or push.

**MUST NOT** run `git push` to create a CR. Mainline is protected — direct pushes are rejected. Instead, commit locally on mainline, then use `cr --new-review` which handles the push itself.

**MUST** run `git pull --rebase origin mainline` before creating a code review (`cr --new-review`). This avoids including stale commits that are already on origin.

### Version Bumps & Changelog

When bumping the version (`VERSION` file), **MUST** also update `CHANGELOG.md` with a new section for that version. Follow the existing format (Keep a Changelog style):
- `## [X.Y.Z] - YYYY-MM-DD` header
- `### Added` / `### Changed` / `### Fixed` subsections as appropriate
- Concise, user-facing descriptions of what changed

### CR workflow (when user says to commit/CR)

1. `git add` the relevant files
2. `git commit` on mainline with a descriptive message
3. `git pull --rebase origin mainline`
4. `cr --new-review` — do NOT `git push` first, `cr` handles it

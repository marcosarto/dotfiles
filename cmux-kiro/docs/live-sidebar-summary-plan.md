# Live Sidebar Summary (v2)

## Problem

1. The `kiro` status pill shows raw tool names (`fs_read`, `execute_bash`) — not human-readable
2. Between tool calls the pill just says "working" — no indication of what the agent is doing
3. There's no high-level summary of what the turn is about — you have to read the terminal to know
4. Stale notification text persists into the next turn

## Solution

Two pills with distinct roles:

### Pill 1: `kiro` — Live Tool Status (set-status)

Shows what the agent is doing right now, tool by tool. Changes rapidly. Uses `cmux set-status` with contextual SF Symbol icons. No log entries for tool calls — avoids duplication.

**In-progress** (tool running): contextual icon per tool type, light grey `#aeaeb2`, present tense description.

| Tool | Icon | Example text |
|---|---|---|
| `fs_read` | `doc.text` | Reading config.ts |
| `fs_write` | `pencil` | Writing plan.md |
| `execute_bash` | `terminal` | Checking git status |
| `InternalSearch` / `*InternalSearch` | `magnifyingglass` | Searching: deploy docs |
| `ReadInternalWebsites` / `*ReadInternalWebsites` | `globe` | Fetching phonetool... |
| `web_search` | `magnifyingglass` | Searching: kiro hooks |
| `web_fetch` | `globe` | Fetching example.com |
| `use_aws` | `cloud` | AWS: s3 list-buckets |
| `QuipEditor` | `doc.on.doc` | Quip: editing doc |
| `use_subagent` | `arrow.triangle.branch` | Delegating to subagent |
| unknown/fallback | `bolt.fill` | (raw tool name) |

**Completed** (tool finished successfully): `checkmark` icon, grey `#aeaeb2`, past tense description.

| Present (in-progress) | Past (completed) |
|---|---|
| Reading config.ts | Read config.ts |
| Writing plan.md | Wrote plan.md |
| Checking git status | Checked git status |
| Running tests | Ran tests |
| Searching: deploy docs | Searched: deploy docs |
| Fetching phonetool... | Fetched phonetool... |

**Between tools** (agent generating text): stays on last completed tool. The green checkmark + past tense makes it clear the tool is done and the agent is thinking.

**Error** (tool failed): `exclamationmark.triangle` icon, red `#ff453a`, "error" text. Unchanged from current behavior.

**Finished** (stop, no errors): `checkmark` icon, grey `#aeaeb2`, "Finished" text. Kiro pill is never cleared — created at agentSpawn, only updated.

**Waiting** (stop, response ends with `?`): `bubble.left.fill` icon, purple `#bf5af2`, "waiting" text. Unchanged.

**Finished with errors** (stop, errors in turn): `exclamationmark.triangle` icon, red `#ff453a`, "done (errors)" text. Unchanged.

### Pill 2: `activity` — Turn Objective

Shows the high-level summary of what the agent is trying to achieve this turn. Stays stable — doesn't change with each tool call.

**Appearance**: `quote.bubble` icon, orange `#ff9500`.

**Example values**: "Implementing auth cookie refresh for browser panels", "Fixing failing tests in cmux-notify.sh", "Researching SIM-1234 requirements"

**Lifecycle**:

| Event | Action |
|---|---|
| `userPromptSubmit` | Fire background kask call to generate activity summary from prompt. |
| kask returns | Set `activity` pill with AI-generated summary. |
| `stop` | Activity stays visible (reminder of what just happened). Color/icon updated to reflect final state: success (green/👍), waiting (purple/💬), errors (red/⚠️). Replaced by next turn's activity. |

**Generation**: Uses `cmux-notifier` agent via kask (same agent as desktop notifications, different mode). The user message asks for an activity summary and the agent returns `{"activity":"..."}`. Max ~60 chars, present tense, specific (include file names, task IDs, search terms when available).

No mid-turn updates — the activity describes the user's intent for the turn, not what tool is running (that's the kiro pill's job). One kask call per turn at `userPromptSubmit`.

### `execute_bash` Smart Descriptions

Raw commands are not descriptive. The `_describe_command()` function maps common binaries to human-readable descriptions:

| Command | Description |
|---|---|
| `grep -rn "pattern" src/` | Searching for pattern |
| `git status` | Checking git status |
| `git add -A && git commit` | Committing changes |
| `cat /tmp/file.txt` | Reading file.txt |
| `ls -la /some/dir` | Listing directory |
| `npm test` | Running tests |
| `echo ... \| nc -U /tmp/cmux.sock` | Sending socket command |
| `cr --new-review` | Creating code review |
| `python3 ~/bin/script.py` | Running script.py |
| `bash -n hooks/cmux-notify.sh` | Running cmux-notify.sh |
| `chmod +x file` | Modifying filesystem |
| `curl https://...` | Fetching URL |
| (unknown) | Running shell command |

### Stale Notification Clearing

At `userPromptSubmit`, clear the previous turn's notification text from the sidebar via `notification.clear`. This fixes "Waiting: ..." persisting while the agent is actively working.

## Visual Summary

```
┌─────────────────────────────────────────┐
│ ◆ Fix Auth Hooks                        │  ← workspace title (sticky across turns)
│                                         │
│ 💬 quote.bubble  Implementing auth      │  ← activity pill (per-turn, orange)
│    cookie refresh                       │
│                                         │
│ 📄 doc.text  Reading config.ts          │  ← kiro pill in-progress (grey)
│    --- or ---                           │
│ ✓  checkmark  Read config.ts            │  ← kiro pill completed (green)
│    --- or ---                           │
│ 👍 hand.thumbsup  finished              │  ← kiro pill at stop (green)
│                                         │
│ 🏷️ tag  SIM-12345                       │  ← task pill (unchanged)
│ 🔀 arrow.triangle.pull  CR-67890        │  ← cr pill (unchanged)
└─────────────────────────────────────────┘
```

## Race Condition Handling

The activity kask call runs in background. If the turn ends before it returns:
- `stop` clears the activity pill and removes `$STATE_DIR/last_summary_time`
- The background script checks for `last_summary_time` before writing — if gone, exits silently

## Files to Change

| File | Change |
|---|---|
| `hooks/cmux-notify.sh` | Add `_tool_description()` with per-tool icons via `_tool_icon()`. Add `_describe_command()` for bash. Add `_tool_result_log()` for enriched log entries with metrics. `preToolUse`: update kiro pill with contextual icon + description (grey). `postToolUse`: kiro pill past-tense + checkmark (grey), log result with metric if available. `stop`: kiro pill "Finished" (grey/✓), activity pill updated with final state color/icon. Activity kask call at `userPromptSubmit` (no placeholder). Workspace-scoped notification clearing. Kiro pill created once at `agentSpawn`, never cleared. |
| `hooks/cmux-summarize-notify.sh` | Add `--activity` mode: takes prompt, returns `{"activity":"..."}`, sets activity pill. |
| `agents/cmux-notifier.json` | Add activity summary mode to system prompt. |
| `.kiro/steering/cmux-kiro-integration.md` | Update hook events table, status pill docs, icon reference. |

## State Files (in `$STATE_DIR`)

| File | Purpose |
|---|---|
| `last_summary_time` | Marker for race condition — removed at stop, checked by background activity script before writing |

## Constraints

- Activity kask call must `unset` cmux env vars before calling kask
- Activity script must be fully detached (`</dev/null >/dev/null 2>&1 & disown`)
- kask output may be wrapped in markdown fences — strip before parsing
- Activity pill text should be ≤60 chars
- `_describe_command()` must handle flags, pipes, `cd` prefixes, env var prefixes, `sudo`
- `_tool_description()` must handle MCP server prefixes (e.g. `@builder-mcp/ReadInternalWebsites`) via glob match

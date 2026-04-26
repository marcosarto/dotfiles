# cmux Feature Map → Kiro Integration Opportunities

## Current Usage (what we have today)

| cmux Feature | Hook Event | What We Do |
|---|---|---|
| `set-status` | agentSpawn, userPromptSubmit, preToolUse, stop | Show working/idle/tool-name in sidebar |
| `log` | all events | Timestamped activity log in sidebar |
| `notify` | stop | Desktop notification on response complete |
| `workspace-action rename` | agentSpawn, userPromptSubmit | Set workspace title (cwd label + AI title) |
| `report_git_branch` | agentSpawn, postToolUse, stop | Git branch + dirty state in sidebar |
| `report_pwd` | agentSpawn, postToolUse, stop | Working directory in sidebar |
| `clear-progress` | stop | Clear any progress bar |

---

## Unused cmux Features → Integration Ideas

### 1. Progress Bar (`set-progress` / `clear-progress`)

Show a visual progress indicator in the sidebar tab.

```bash
cmux set-progress 0.5 --label "Running tests"
cmux clear-progress
```

**Kiro integration**: Track tool calls within a turn. If the agent calls N tools, show progress as each completes. Could also show progress during long `execute_bash` runs.

**Hook**: `preToolUse` (increment), `stop` (clear)

---

### 2. Markdown Panel (`cmux markdown open`)

Render a `.md` file in a split panel with live reload.

```bash
cmux markdown open plan.md
```

**Kiro integrations**:
- **Plan display**: When using `/plan`, write the plan to a file and open it in a markdown panel. Updates live as the plan evolves.
- **Task context**: Show current Taskei sprint/task details in a sidebar panel.
- **CR summary**: Show CRUX CR description and reviewer comments alongside the terminal.
- **Session summary**: On `stop`, write a session summary to a markdown file.

**Hook**: `agentSpawn` (open), `stop` (update summary)

---

### 3. Browser Panel (`cmux browser open`)

Open a URL in a sidebar webview with full interaction support.

```bash
cmux browser open https://taskei.amazon.dev/tasks/TASK-1234
```

**Kiro integrations**:
- **Taskei board**: Open the sprint board or task detail page alongside the terminal.
- **CR review**: Open a CRUX code review in the sidebar for reference.
- **Pipeline status**: Open the pipeline dashboard while debugging deployment issues.
- **Documentation**: Open relevant AWS docs or wiki pages mentioned in conversation.

**Hook**: `userPromptSubmit` (detect URLs/task IDs in prompt, auto-open)

---

### 4. Trigger Flash (`cmux trigger-flash`)

Flash a surface to draw attention.

```bash
cmux trigger-flash --surface surface:7
```

**Kiro integration**: Flash the workspace tab when a long-running background task completes (e.g., delegate finishes).

**Hook**: `stop` (after long turns)

---

### 5. Multi-Status Keys

`set-status` supports multiple keys per workspace — we only use `kiro` today.

**Kiro integrations**:
- `cmux set-status task "TASK-1234" --icon tag` — show active Taskei task
- `cmux set-status cr "CR-567890" --icon git-pull-request` — show active CR
- `cmux set-status model "haiku" --icon cpu` — show current model

---

### 6. Notifications with Actions (`cmux notify`)

Already used for completion, but could be richer.

**Kiro integrations**:
- Notify on CR approval/rejection
- Notify when a delegated task completes
- Notify on test failures with context

---

## CRUX / Code Review Integration

### What CRUX Provides
- CLI: `cr` command for creating/managing code reviews
- Rules: configurable at `code.amazon.com/gc/rules/llms.txt`
- Templates: `.crux_template.md` with `{{commit_message}}` macro
- Pre-CR hooks: `~/.config/cr/hooks/pre-cr`
- SNS events: CR lifecycle (publish, approve, merge, close)

### Integration Opportunities

#### A. Auto-generate CR description (postToolUse on `execute_bash`)
When detecting `cr --create` or similar, auto-generate a description from the conversation context.

```bash
# In postToolUse, detect cr commands
if echo "$TOOL_INPUT" | grep -q 'cr '; then
    # Extract CR ID from output, set status
    cmux set-status cr "CR-XXXXXX" --icon git-pull-request --color "#bf5af2"
fi
```

#### B. CR context injection (userPromptSubmit)
When a CR ID is mentioned in a prompt, fetch CR details and inject as context.

```bash
# Detect CR-XXXXXX in prompt
if [[ "$PROMPT" =~ CR-([0-9]+) ]]; then
    CR_ID="CR-${BASH_REMATCH[1]}"
    # Fetch CR details and output as context (stdout goes to agent)
    echo "Active CR: $CR_ID"
fi
```

#### C. CRUX rules awareness (agentSpawn)
Load the package's CRUX rules so the agent knows what reviewers will check.

```bash
# On session start, check for CRUX rules
if [ -f ".crux_template.md" ]; then
    echo "CRUX template found: $(cat .crux_template.md)"
fi
```

#### D. CR status in sidebar
Show active CR status as a persistent sidebar status item.

---

## Taskei Integration

### What Taskei Provides
- MCP tools: `TaskeiGetTask`, `TaskeiListTasks`, `TaskeiCreateTask`, `TaskeiUpdateTask`
- Web UI: `taskei.amazon.dev/tasks/TASK-ID`
- Rooms, sprints, kanban boards, task hierarchy
- Comments (markdown), labels, priority, estimates

### Integration Opportunities

#### A. Task context injection (userPromptSubmit)
When a task ID is mentioned in a prompt, auto-fetch and inject task details.

```bash
# Detect TASK-XXXXXX or SIM-XXXXXX patterns
if [[ "$PROMPT" =~ ([A-Z]+-[0-9]+) ]]; then
    TASK_ID="${BASH_REMATCH[1]}"
    cmux set-status task "$TASK_ID" --icon tag --color "#64d2ff"
    echo "Working on task: $TASK_ID"
fi
```

#### B. Sprint dashboard (agentSpawn)
On session start, show current sprint tasks in a markdown panel.

#### C. Auto-update task status (stop)
After a turn completes, post a summary comment to the active Taskei task.

#### D. Task board in browser panel
Open the Taskei board alongside the terminal.

```bash
cmux browser open "https://taskei.amazon.dev/tasks/$TASK_ID"
```

---

## Recommended Implementation Priority

### Phase 1 — Quick Wins (hook changes only)
1. **Multi-status keys**: Show task ID, CR ID, model in sidebar
2. **CR/Task ID detection**: Parse prompts for IDs, set status items
3. **Progress bar**: Track tool calls within a turn

### Phase 2 — Markdown Panels
4. **Plan display**: `/plan` output in markdown panel
5. **Session summary**: Write turn summaries to a live markdown file
6. **Sprint context**: Show sprint tasks on session start

### Phase 3 — Browser Integration
7. **Taskei board**: Open task details in sidebar
8. **CR review**: Open CRs in sidebar webview
9. **Auto-open URLs**: Detect URLs in prompts, offer to open in sidebar

### Phase 4 — Deep Integration
10. **CR description generation**: Auto-generate from conversation context
11. **Task progress tracking**: Auto-comment on Taskei tasks
12. **CRUX rules loading**: Inject package review rules into agent context

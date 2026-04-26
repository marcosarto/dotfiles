# CMUX-8: Include links to CRs raised outside of Kiro, but in the same workspace

## Summary

Currently, CR detection only works when:
1. The user mentions `CR-XXXXX` in a Kiro prompt (`userPromptSubmit` hook)
2. Kiro runs `cr --new-review` and the output is captured (`postToolUse` hook on `execute_bash`)

CRs created in a **different terminal pane** within the same cmux workspace (e.g., the user runs `cr` manually) are invisible to the sidebar. This task adds detection for those CRs.

## Approach

CRUX CLI supports **pre-cr hooks** (`~/.config/cr/hooks/pre-cr`) but not post-cr hooks. Since we need the CR ID (which only exists *after* `cr` runs), pre-cr hooks aren't sufficient.

**Chosen approach: shell wrapper function + CRUX pre-cr hook (belt and suspenders)**

1. **Shell wrapper function** — A `cr()` shell function in the user's `.zshrc` that wraps `command cr`, captures stdout, extracts `CR-XXXXXX` from the output, and sends it to the cmux sidebar. This catches CRs from any terminal pane in the workspace.

2. **CRUX pre-cr hook** — A `~/.config/cr/hooks/pre-cr` script that logs the workspace context (package name, git branch) to the cmux sidebar log before the CR is created. This gives immediate "creating CR..." feedback.

Both are installed by `setup.sh` and are no-ops outside cmux (guard on `$CMUX_SOCKET_PATH`).

## Step 1: Create `lib/cr-hook.sh` — post-CR sidebar updater

A standalone script that:
- Takes a CR ID as `$1` (e.g., `CR-12345678`)
- Guards on `$CMUX_SOCKET_PATH` — exits silently if not in cmux
- Calls `cmux set-status cr "CR-XXXXX" --icon arrow.triangle.pull --color "#bf5af2" --url "https://code.amazon.com/reviews/CR-XXXXX"`
- Calls `cmux log --level success --source kiro "[HH:MM] CR-XXXXX created"`
- Persists the CR ID to `$STATE_DIR/last_cr` to avoid duplicate updates

This script is reusable — called by both the shell wrapper and any future integration.

## Step 2: Create `lib/cr-wrapper.sh` — shell function source file

A file designed to be `source`d from `.zshrc` / `.bashrc`:

```bash
# Guard: only define wrapper inside cmux
if [ -n "$CMUX_SOCKET_PATH" ] && [ -S "$CMUX_SOCKET_PATH" ]; then
  cr() {
    local output
    output=$(command cr "$@" 2>&1 | tee /dev/stderr)
    local cr_id
    cr_id=$(echo "$output" | grep -o 'CR-[0-9]\+' | head -1)
    if [ -n "$cr_id" ]; then
      ~/.cmux-kiro/lib/cr-hook.sh "$cr_id"
    fi
  }
fi
```

Key details:
- `tee /dev/stderr` preserves normal `cr` output for the user while capturing it
- Only wraps when inside cmux — zero overhead otherwise
- Calls `lib/cr-hook.sh` for the actual sidebar update

## Step 3: Create `hooks/pre-cr` — CRUX pre-CR hook

Installed to `~/.config/cr/hooks/pre-cr`:

- Guards on `$CMUX_SOCKET_PATH`
- Logs `"Creating code review..."` to cmux sidebar
- Sets a transient status pill: `cmux set-status cr "creating..." --icon arrow.triangle.pull --color "#ff9500"`
- Always exits 0 (never blocks CR creation)

## Step 4: Update `setup.sh` — install the new hooks

In the setup flow, add:

1. **Source line in shell RC** — Append `source ~/.cmux-kiro/lib/cr-wrapper.sh` to `~/.zshrc` (idempotent — check if already present via grep before appending). Interactive prompt: `"Add CR detection to your shell? [Y/n]"`.

2. **CRUX pre-cr hook** — Create `~/.config/cr/hooks/` dir, symlink `pre-cr` → `$INSTALL_DIR/hooks/pre-cr`. If a `pre-cr` already exists and isn't ours, warn and skip (don't clobber user's existing hook). Check via readlink.

3. **Removal support** — Add `--remove-hooks` handling for both: remove the source line from `.zshrc`, remove the `pre-cr` symlink if it points to our repo.

## Step 5: Update `doctor.sh` — check CR integration

Add checks:
- Is `cr-wrapper.sh` sourced in `.zshrc`?
- Is `~/.config/cr/hooks/pre-cr` symlinked correctly?
- Warn if either is missing with fix instructions.

## Step 6: Update docs

- `README.md` — Add a "CR Detection" section under features explaining that CRs from any pane are detected
- `steering/cmux-kiro-usage.md` — No changes needed (sidebar pills are already documented)
- `CHANGELOG.md` — Add entry

## Files to create

| File | Purpose |
|---|---|
| `lib/cr-hook.sh` | Reusable CR → sidebar updater |
| `lib/cr-wrapper.sh` | Shell function wrapper for `cr` CLI |
| `hooks/pre-cr` | CRUX pre-CR hook for "creating..." feedback |

## Files to modify

| File | Change |
|---|---|
| `setup.sh` | Install cr-wrapper source line + pre-cr symlink |
| `doctor.sh` | Add CR integration health checks |
| `README.md` | Document CR detection feature |
| `CHANGELOG.md` | Add entry |

## Why This Works Across Panes

cmux exports `CMUX_WORKSPACE_ID`, `CMUX_TAB_ID`, `CMUX_PANEL_ID`, and `CMUX_SOCKET_PATH` to **every** shell session in the workspace — not just the Kiro pane. So the `cr()` wrapper running in a separate terminal pane has full access to the same workspace context. `lib/cr-hook.sh` derives `STATE_DIR="/tmp/kiro-cmux-$CMUX_WORKSPACE_ID"` and writes to the same state files the Kiro hooks use, ensuring the sidebar pill appears on the correct workspace.

## Edge Cases

1. **User already has a `pre-cr` hook** — Don't clobber. Warn and suggest they chain ours: `~/.cmux-kiro/hooks/pre-cr "$@"` at the end of their hook.
2. **Multiple CRs in one `cr` output** (multi-package) — `grep -o 'CR-[0-9]\+'` captures all; use `head -1` for the pill, log all.
3. **`cr -r` (update existing CR)** — The wrapper still captures the CR ID from output and updates the pill. The `--url` flag ensures the link is always correct.
4. **Not in a Brazil workspace** — `cr` won't run anyway, so no special handling needed.
5. **Shell compatibility** — Wrapper uses POSIX-compatible syntax. Works in zsh and bash. The `source` line in `.zshrc` is zsh-specific; if we detect `.bashrc` as primary, source there instead.

## Complexity

Low-medium. The core logic (capture `cr` output, extract CR ID, update sidebar) is straightforward. The setup integration (idempotent shell RC modification, symlink management, removal) is the fiddliest part.

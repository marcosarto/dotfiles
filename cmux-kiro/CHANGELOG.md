# Changelog

All notable changes to kiro-cmux are documented in this file.

## [0.1.36] - 2026-04-14

### Fixed
- Fix CR detection and tool result tracking broken in new Kiro TUI — the TUI uses a different `postToolUse` event payload structure (`{items: [{Json, Text}]}`) vs the old CLI (`{success, result}`). Added `_tool_response_text()` helper that handles both formats.

### Added
- `tests/test-event-formats.sh` — validates postToolUse event parsing across old CLI and new TUI payload formats
- Steering doc: "Debugging Kiro CLI Internals" section with `gh` CLI commands and key source paths for investigating kiro-cli hook integration issues
- Steering doc: gotcha #16 documenting TUI vs CLI event format differences

## [0.1.35] - 2026-04-14

### Fixed
- Read tool sidebar description now shows "Listing directory" instead of "Read ." for Directory mode calls
- Read tool sidebar description now shows "Viewing image" for Image mode calls
- `code` tool sidebar description now reads correct input params (`.operation`/`.symbol_name` instead of non-existent `.query`) — shows context-aware labels like "Finding myFunc", "Checking diagnostics", "Mapping codebase"
- `WorkspaceSearch` sidebar description now reads `.searchQuery` (the actual param) instead of `.query` — search terms now appear in the sidebar
- Updated test-tool-descriptions.sh to test against correct tool input schemas

## [0.1.34] - 2026-04-13

### Fixed
- Fix AI title generation silently failing — the session guard used `$PPID` which is a transient hook-runner process, causing every title write to be aborted. Replaced with a stable random token written at session start.

## [0.1.33] - 2026-04-09

### Fixed
- Setup now detects existing `cr` alias in `.zshrc` and asks before replacing — previously, sourcing `cr-wrapper.sh` caused a zsh parse error (`defining function based on alias`) for users with a pre-existing `alias cr=...`

## [0.1.31] - 2026-04-01

### Fixed
- Remote setup now installs steering file (`cmux-kiro-usage.md`) — Kiro on SSH remote didn't know how to open browser panels or use cmux commands
- Remote setup now installs `cmux-activity.json` agent — activity pills weren't working on remote
- `cmux-activity.json` added to laptop `setup.sh` agent symlink list (was missing, doctor flagged it but setup never installed it)
- All three setup scripts now detect stale `k` alias (missing `--agent cmux`) and offer to update it, instead of silently skipping

### Added
- `k` and `kask` shell aliases now installed by both remote setup scripts (previously laptop-only)
- `kssh` alias offered at end of `kmux setup-remote` — shorthand for `kmux ssh <host>`
- `tests/test-remote-setup.sh` — validates setup parity across all three setup scripts (agents, steering, aliases)
- Steering gotcha #15: setup parity rule to prevent future drift between local and remote setup scripts

## [0.1.30] - 2026-03-31

### Fixed
- kask cold-start timeout cascade — first prompt after ACP init now gets 15s timeout (was 10s), preventing repeated timeout → crash → restart cycles that caused 14-27s spikes when multiple agents cold-start simultaneously

### Added
- `kmux doctor` now checks for `cmux-activity.json` agent config and includes it in kask smoke tests
- `kmux doctor` warns when warm kask responses exceed 5s (backend latency indicator)
- kask debug logging — auto-enabled in dev mode (symlinked `~/.cmux-kiro`) or via `KASK_DEBUG=1`, writes timestamped traces to `/tmp/kask/<agent>.debug.log`
- kask captures kiro-cli stderr and logs last 10 lines on prompt failure for diagnostics

## [0.1.29] - 2026-03-31

### Fixed
- Setup no longer fails silently on stable kiro-cli — `hooks.showStatus` setting only exists on nightly, was triggering `set -e` and aborting setup before the success banner
- Webhook error reporting now includes which setup step failed (`error:agent_configs` instead of generic `error`)
- Background auto-update now reports `fetch_failed` and `pull_failed` to webhook (previously silent)

## [0.1.28] - 2026-03-30

### Fixed
- Hooks survive cmux socket path changes — if the configured socket disappears (e.g. cmux update moves it), hooks now probe known fallback paths automatically instead of silently failing
- `kmux doctor` detects socket path mismatches after cmux updates and tells you to restart cmux instead of the unhelpful "run setup.sh"

## [0.1.27] - 2026-03-30

### Added
- Hide kiro-cli's built-in hook status display (`hooks.showStatus false`) — kiro-cmux provides its own sidebar status. Applied during setup, auto-update, and checked by `kmux doctor`

## [0.1.26] - 2026-03-27

### Fixed
- Activity pill no longer leaks topics from other workspaces — added conversation isolation to the activity prompt so the shared kask daemon doesn't bleed context across workspaces
- Disable Kiro's built-in OSC 9 terminal notifications during setup — prevents duplicate notifications clashing with kiro-cmux's AI-summarized ones
- `kmux doctor` checks for and warns about Kiro built-in notifications being enabled

## [0.1.25] - 2026-03-26

### Added
- `kmux doctor` checks for missing xterm-ghostty terminfo on SSH remotes — reports clear fix instructions

### Fixed
- `cmux-ssh` falls back to `TERM=xterm-256color` when xterm-ghostty terminfo is missing on remote — prevents garbled terminal (doubled characters, broken backspace) over SSH

## [0.1.24] - 2026-03-26

### Fixed
- Activity pill text reduced from 60 to 30 char limit to fit cmux sidebar default width without truncation

## [0.1.23] - 2026-03-25

### Added
- `kmux sync <host>` command — rsync local changes to a remote host without full setup
- `kmux doctor` now tests socket connectivity (ping + notification) with spinner animation
- `kmux doctor` shows system info (macOS version / Linux distro), cmux version, and kiro-cli version
- Ghostty terminfo auto-installed on remote during `cmux-ssh`, `setup-remote`, and `setup-remote-push` — fixes "unknown terminal type" errors
- `kiro-cmux` and `kmux` alias installed on remote during setup and sync

### Fixed
- `kmux doctor` cross-platform `stat` for Midway cookie age (Linux uses `-c %Y`, macOS uses `-f %m`)
- `cmux-ssh` suppresses stdout noise from `set-status`/`clear-status` calls

## [0.1.22] - 2026-03-23

### Fixed
- Activity pill no longer shows stale state (Waiting/Done/Error) from previous turn when user sends a new prompt — immediately transitions to "Working: <description>" preserving the activity context

## [0.1.21] - 2026-03-20

### Fixed
- Steering doc for manual task/CR pills used `cmux set-status --url` but the native CLI doesn't support `--url` — value got corrupted with URL embedded in label. Changed to raw socket which correctly parses `--url=`

## [0.1.20] - 2026-03-20

### Added
- `kmux` as short alias for `kiro-cmux` CLI — backwards compatible, auto-detected via `basename $0`
- Comprehensive Python test suite for kask (20 tests: one-shot, daemon lifecycle, agent isolation, recovery, concurrency, timeouts, cleanup)
- kask daemon self-healing — automatically recovers when ACP subprocess dies mid-session
- `test-daemon-recovery.sh` smoke test for daemon self-healing

### Changed
- README, doctor, setup, update, and remote setup all use `kmux` as primary command name
- kask timeouts tightened: daemon prompt 10s, caller socket 15s, handshake 10s
- Dev-mode setup uses symlinks instead of copies for instant edit propagation

### Fixed
- Task/CR pills preserved across title refinements — only cleared on actual task change
- `cmux-ssh` usage error handling

## [0.1.18] - 2026-03-19

### Added
- Human-readable tool pills — sidebar shows contextual descriptions and icons for each tool call (e.g. "Reading config.ts" with doc icon) instead of raw tool names
- Activity pill — AI-generated turn objective shown in sidebar during work, updated with final state (success/waiting/error) on completion
- `cmux-activity` agent for activity pill summaries
- Tests for activity pill (`test-activity.sh`) and user-set title preservation (`test-user-title.sh`)

### Changed
- kask uses `fcntl.flock()` per-agent lock file to prevent duplicate daemon spawns from concurrent callers
- kask kills full process group on construction failure to prevent leaks

### Fixed
- CR detection scoped to actual `cr` commands — prevents false positives from `git log` output containing `CR-` strings
- CR detection reads full tool response JSON instead of truncated 200-char `TOOL_RESULT`

## [0.1.17] - 2026-03-19

### Added
- Multi-workspace SSH scoping — shim injects `--tab` from env vars so concurrent SSH sessions don't cross-talk
- Taskei project board link and MCP usage note in steering doc

### Changed
- Show idle status (green/✓) on `agentSpawn` instead of working

### Fixed
- CR pill race condition — pill cleared only on topic change, not when titler returns empty `.cr`
- Stale "Creating CR..." pill cleanup when `cr` fails or is cancelled

## [0.1.16] - 2026-03-19

### Changed
- Notification summaries include concrete results with screen context fallback (23 tests)
- Disable "Reorder on Notification" in cmux settings to fix notification workspace targeting

## [0.1.15] - 2026-03-19

### Added
- SSH remote mode — run Kiro on a cloud desktop over SSH with full sidebar integration on your laptop. Python3 shims for `cmux` and `nc`, one-command setup via `kiro-cmux setup-remote`, connect via `kiro-cmux ssh`
- Preserve user-set workspace titles — manual renames disable auto-titling for that session

## [0.1.14] - 2026-03-18

### Changed
- Switch titler/notifier agents from glm-4.7-flash to kimi-k2.5
- Doctor checks that `kiro-cmux` CLI is on PATH

## [0.1.13] - 2026-03-18

### Fixed
- Broken CR hook
- Doctor: add kask smoke tests for all three agents

## [0.1.12] - 2026-03-18

### Fixed
- kask process leak — kill full process group on close (`os.killpg`) instead of just direct child
- Ensure `~/bin` is on PATH for older users who installed before `kiro-cmux` existed
- Remove generated `cmux.json` from repo (now in `.gitignore`)
- Remove unintentional Vercel context

## [0.1.11] - 2026-03-18

### Fixed
- Ensure `kiro-cmux` CLI is on PATH after install/update

## [0.1.10] - 2026-03-18

### Fixed
- Version-based update check, bootstrap-proof `update.sh`, telemetry status field

## [0.1.9] - 2026-03-18

### Added
- Title generation tests

## [0.1.6] - 2026-03-17

### Added
- Inject cmux hooks into all agents during setup — no need to use a specific agent
- CR detection from non-Kiro panes (CMUX-8)

### Changed
- CR extraction refined — titler extracts task/CR on SAME responses too

### Fixed
- Markdown panel pane reuse scoped to workspace, with detection before open
- Suppress git pull stdout leak in telemetry
- Restore CR pill management in title script, remove debug logs

## [0.1.5] - 2026-03-17

### Added
- kask daemon mode with glm-4.7-flash and 15-minute idle timeout
- Daemon test suite (`test-daemon.sh`)

### Fixed
- Titler not updating title on topic change

## [0.1.4] - 2026-03-17

### Added
- kask daemon mode with 15-minute idle timeout

## [0.1.3] - 2026-03-17

### Added
- Bundle kask: install `kiro-acp-client.py` and `fast.json` via `setup.sh`
- Sidebar close-up screenshot in README

## [0.1.2] - 2026-03-17

### Added
- CR detection from any pane — `cr` commands in non-Kiro terminal panes now pin CRs to the sidebar
- Shell wrapper (`lib/cr-wrapper.sh`) captures CR IDs from `cr` CLI output
- CRUX pre-CR hook (`hooks/pre-cr`) shows "creating..." feedback before CR is created
- Reusable CR sidebar updater (`lib/cr-hook.sh`)
- Doctor checks for CR integration (cr-wrapper sourced, pre-cr hook linked)
- Setup installs CR wrapper in `.zshrc` and symlinks CRUX pre-cr hook
- `--remove-hooks` cleans up CR wrapper and pre-cr hook

## [0.1.1] - 2026-03-16

### Added
- Build script (`build.sh`) with syntax checks, template validation, JSON validation, and version check
- Test runner (`test.sh`) for running all test suites
- Auto-update mechanism with background checks and desktop notifications
- Browser auth library with SSO cookie flow, URL rewriting, and user config
- Interactive setup script and quick-start one-liner
- Developer setup instructions in Contributing section

### Changed
- Reorganized repo into `hooks/`, `lib/`, `agents/`, `tests/`, `docs/`
- Renamed package to AmznCmuxKiroTools
- Browser panels now use `open-split` with pane reuse
- Sidebar task/CR pills are now clickable with URLs
- Use `CMUX_SOCKET_PATH` instead of hardcoded `/tmp/cmux.sock`

### Removed
- BACKLOG.md (moved to issue tracking)
- Duplicate Developer Setup section (merged into Contributing)

## [0.1.0] - 2026-03-13

### Added
- Initial cmux hook integration for Kiro CLI (sidebar updates, tool call visibility)
- AI-powered desktop notifications via kask ACP with smart summarization
- AI-generated workspace titles via Kiro subagent
- Live markdown preview — files written by Kiro open automatically in a viewer panel
- Browser panels with curl SSO pre-auth and auto cookie refresh
- SIM & CR tracking with automatic detection and sidebar pills
- Taskei + CRUX sidebar integration
- Git branch and dirty state shown in sidebar
- Markdown panel dedup to prevent duplicate panels on every `fs_write`
- Notification body starts with "Waiting:" when agent asks a question
- Markdown files open as tabs in a dedicated pane instead of separate splits
- Local `.kiro/steering` for cmux integration context
- README with screenshot, feature overview, shell alias, troubleshooting

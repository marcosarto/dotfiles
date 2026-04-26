# kiro-cmux

First-class [Kiro CLI](https://kiro.dev) integration for [cmux](https://cmux.dev) — turning your terminal multiplexer into an AI-aware workspace.

> **cmux is a standalone macOS terminal app** — not a tmux plugin or library. You open cmux like you'd open iTerm or Ghostty, then run Kiro inside it. The sidebar, browser panels, and notifications are all part of the cmux app.  This package sets up cmux for Amazonians with full Kiro integration and internal tool support out of the box.

> ⚠️ **Beta** — Things will break. Feedback welcome in [#cmux-interest](https://amzn-aws.slack.com/archives/cmux-interest) on Slack.

## 🚀 Install

> **One command, ~10 seconds.** Copy and paste into your terminal.

If you installed cmux manually (not via Homebrew), uninstall it first — the setup will reinstall it via Homebrew.

```bash
[[ "$(curl -s -b ~/.midway/cookie https://midway-auth.amazon.com/api/session-status 2>/dev/null | jq -r .authenticated)" == "true" ]] || mwinit; git clone ssh://git.amazon.com/pkg/AmznCmuxKiroTools ~/.cmux-kiro || { printf "\n❌ Setup failed — ~/.cmux-kiro already exists.\n    To reinstall: rm -rf ~/.cmux-kiro && re-run this command\n\n"; false; } && ~/.cmux-kiro/setup.sh
```

The setup script checks for dependencies ([cmux](https://cmux.dev), `jq`, `kiro-cli`), offers to install anything missing via Homebrew, and injects cmux hooks into all your agent configs. Sidebar integration works with any agent — no need to switch agents.

## Features

- 🔔 AI-summarized notifications when Kiro finishes a task
- ✏️ Live workspace titles that update as your task evolves
- 🎯 At-a-glance activity tracking — see what Kiro is working on without opening the chat
- 🔨 Every tool call narrated in the sidebar — "Searching code", "Writing tests"
- 🏷️ Automatic SIM/Taskei & CR detection with clickable sidebar links 
- 🌐 Authenticated internal site browsing (Phonetool, SIM, Code Browser)
- 📄 Live markdown preview for files Kiro writes
- ☁️ SSH remote mode — run Kiro on your cloud desktop, get sidebar updates, titles, and notifications on your laptop
- 🌿 Git branch and Brazil package detection

> *Kiro finished a task while you were in another tab? You'll get an AI-written summary of what happened.*

![](https://code.amazon.com/packages/AmznCmuxKiroTools/blobs/mainline/--/assets/img/cmux-overview.png?raw=1)

*At-a-glance summary of multiple agent threads — titles, status, tasks, and activity in the sidebar.*

![Sidebar close-up showing workspace titles, status pills, task detection, and activity log](https://code.amazon.com/packages/AmznCmuxKiroTools/blobs/mainline/--/assets/img/cmux-sidebar.png?raw=1)



![](https://code.amazon.com/packages/AmznCmuxKiroTools/blobs/mainline/--/assets/img/cmux-notifications.png?raw=1)

*Live markdown preview panel — Kiro writes a plan, you see it rendered in real time.*

![](https://code.amazon.com/packages/AmznCmuxKiroTools/blobs/mainline/--/assets/img/cmux-markdown.png?raw=1)

### Usage

```bash
# Any agent works — sidebar, notifications, and status are automatic
kiro-cli chat -a

# Or use the curated cmux agent (includes builder-mcp, steering docs)
k
```

### Removing hooks

To remove cmux hooks from your agents:

```bash
kmux setup --remove-hooks
```

An interactive picker lets you choose which agents to clean up. A backup is created before any changes.

## SSH Remote Mode

Run Kiro on a cloud desktop over SSH — sidebar, titles, notifications, and CR detection all work on your laptop.

```bash
# One-time setup (from laptop, inside cmux):
kmux setup-remote <hostname>

# Every session:
kmux ssh <hostname>
# Then on the remote:
k
```

`setup-remote` rsyncs the repo to the remote, installs python3 shims for `cmux` and `nc` (neither available on Linux), injects hooks into all agents, and sets up CR detection. Nothing to install manually on the remote.

`kmux ssh` reverse-forwards the cmux socket, exports workspace env vars, shows a hostname pill in the sidebar, and auto-syncs if the remote version is out of date. When you disconnect, the hostname pill clears automatically.

### Session Persistence with tmux

By default, if your SSH connection drops, the remote Kiro session is lost. Add `--tmux` to wrap the remote shell in a tmux session that survives disconnects:

```bash
# Default session name "kmux"
kmux ssh <hostname> --tmux

# Explicit session name
kmux ssh <hostname> --tmux=my-session
```

Reconnecting from the same tab reattaches to the same tmux session — your Kiro conversation is right where you left it.

To make this the default for all `kmux ssh` connections:

```bash
echo 'CMUX_SSH_TMUX=true' >> ~/.config/cmux-kiro/config
```

> Works with any cloud desktop that has `python3`, `jq`, and `kiro-cli`. Session persistence (`--tmux`) also requires `tmux` 2.0+ on the remote.

## Updating

kiro-cmux checks for updates automatically when you start a Kiro session inside cmux (once per day, in the background — no delay to your session). When an update is applied, you'll get a desktop notification showing the version change.

```bash
# Manual update
kmux update

# Manual update (older versions without kmux)
~/.cmux-kiro/update.sh

# Check current version
kmux --version
```

## Configuration

Optional settings live in `~/.config/cmux-kiro/config` (plain shell variables, sourced at startup). All features are enabled by default — add this file only to disable things.

| Setting | Default | Description |
|---|---|---|
| `CMUX_COOKIE_REFRESH` | `true` | Background daemon that re-injects fresh cookies into browser panels after `mwinit` |
| `CMUX_AUTO_UPDATE` | `true` | Background update check on session start (once per day) |
| `CMUX_RAW_TOOL_NAMES` | `false` | Show raw tool names (e.g. `fs_read`) instead of human-readable descriptions (e.g. `Reading config.ts`) in the sidebar |
| `CMUX_AUTO_OPEN_MD` | `true` | Auto-open markdown files as sidebar panels when Kiro writes `.md` files |
| `CMUX_AUTO_TITLE` | `true` | AI-generated workspace titles and task detection. Set `false` to keep your own workspace names |
| `CMUX_TELEMETRY` | `true` | Reports feature usage and errors |
| `CMUX_SSH_TMUX` | `false` | Wrap `kmux ssh` sessions in tmux on the remote host for session persistence. Default session name is `kmux`, or specify with `--tmux=<name>`. |

```bash
mkdir -p ~/.config/cmux-kiro
echo 'CMUX_AUTO_UPDATE=false' >> ~/.config/cmux-kiro/config
```

Or just ask Kiro:

> Read my cmux-kiro config at ~/.config/cmux-kiro/config (create it if it doesn't exist). Show me the current settings and their values. The available settings are CMUX_COOKIE_REFRESH (background cookie refresh daemon) and CMUX_AUTO_UPDATE (background auto-update), both default true, CMUX_RAW_TOOL_NAMES (show raw tool names instead of descriptions), default false, CMUX_AUTO_OPEN_MD (auto-open markdown panels), default true, CMUX_AUTO_TITLE (AI workspace titles and task detection), default true, CMUX_TELEMETRY (usage and error reporting), default true, and CMUX_SSH_TMUX (wrap kmux ssh in tmux for session persistence), default false. Ask me which setting I want to change, then update the file.

## Troubleshooting

Run the doctor script to check your setup:

```bash
kmux doctor
```

| Problem | Fix |
|---|---|
| Sidebar not updating / hooks doing nothing | Make sure you're inside a cmux workspace (`echo $CMUX_SOCKET_PATH`). Also check your agent has hooks: `jq .hooks ~/.kiro/agents/YOUR_AGENT.json`. If missing, re-run `kmux setup`. |
| Hooks stopped working after cmux update | cmux 0.62.2 moved the socket path. Run `kmux update` (or `cd ~/.cmux-kiro && git pull --rebase origin mainline && ./setup.sh` if you don't have `kmux` yet). |
| "socket not found" | Set cmux socket control to at least `Automation mode`: Settings (⌘,) → Socket Control → Automation mode. Setup configures this automatically. |
| Titles/notifications not generating | Requires [kask](docs/warm-acp-client.md). Without it, titles fall back to directory name and notifications to "Response complete". Run `./tests/test-titler.sh` to verify. |
| Agent config out of sync | Re-run `kmux setup` to regenerate configs and re-inject hooks. |
| Notifications go to wrong workspace | Disable "Reorder on Notification" in cmux Settings (⌘,) → App. This is a [known cmux bug](https://github.com/manaflow-ai/cmux/pull/1799) where notification surface targeting ignores the explicit workspace/surface ID. Setup disables this automatically. |
| Duplicate notifications (OSC 9) | Kiro CLI can send its own terminal notifications via OSC 9, which clash with kiro-cmux's AI-summarized ones. Setup disables this automatically (`chat.enableNotifications false`). To re-enable for non-cmux terminals: `kiro-cli settings chat.enableNotifications true`. |

## Requirements

- [cmux](https://cmux.dev) — a **standalone macOS terminal app** (not a library or tmux plugin). You run Kiro *inside* cmux, which provides the sidebar, browser panels, and notifications. Install: `brew install --cask cmux`
- `jq` (`brew install jq`)
- [Kiro CLI](https://kiro.dev)

## Contributing

```bash
# Create a Brazil workspace
brazil ws create --name AmznCmuxKiroTools --versionSet live
cd /Volumes/workplace/AmznCmuxKiroTools
brazil ws use -p AmznCmuxKiroTools

# Point ~/.cmux-kiro to your workspace (dev mode — auto-updates disabled)
rm -rf ~/.cmux-kiro
ln -s /Volumes/workplace/AmznCmuxKiroTools/src/AmznCmuxKiroTools ~/.cmux-kiro
~/.cmux-kiro/setup.sh
```

Edits in your workspace take effect immediately — no copy or rebuild step.

1. Make your changes on mainline (to avoid complicated merges)
2. Push and raise a CR on [code.amazon.com/packages/AmznCmuxKiroTools](https://code.amazon.com/packages/AmznCmuxKiroTools)
3. Add [`bssas`](https://phonetool.amazon.com/users/bssas) (Ben Sassoon) as a reviewer
4. Post the CR link in [#cmux-interest](https://amzn-aws.slack.com/archives/cmux-interest) on Slack for visibility

## Known Gaps

- **New agents require re-running setup** — The setup script injects cmux hooks into all existing agent configs at install time. If you create new agents after setup, run `kmux setup` again to add hooks to them.

## Known Bugs

- **SPA sites don't authenticate in browser panels** — Sites that use client-side JavaScript auth (React/Next.js SPAs like Taskei) show "Midway session expired" even after cookie injection. Root cause: the SPA's `fetch()` calls to API subdomains trigger 302 redirects to `midway-auth.amazon.com`, which requires mTLS that WKWebView can't do. Server-rendered sites (SIM, Phonetool, Code Browser) work fine because all auth happens in the initial HTTP redirect chain that curl handles. Workaround: taskei task URLs are automatically rewritten to `issues.amazon.com` (SIM), which is server-rendered. A proper fix requires cmux adding mTLS/client certificate support to WKWebView.
- **Prompt shows `~_CMUX_PR_POLL_PWD` instead of directory name** — cmux's zsh integration sets `_CMUX_PR_POLL_PWD` to your current directory. Zsh's `%~` prompt expansion (used by oh-my-zsh and ghostty's title-setting) can pick this up as a named directory when `~_CMUX_PR_POLL_PWD` is shorter than the `~/...` path. Fix: add `unsetopt AUTO_NAME_DIRS` to your `~/.zshrc` after oh-my-zsh is sourced.

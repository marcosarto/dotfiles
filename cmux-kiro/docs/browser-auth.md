# cmux Browser Authentication for Amazon Internal Sites

## Problem

cmux's browser panel uses macOS WKWebView, which can't do two things needed for internal sites:
1. Load the AEA browser extension (for posture cookies)
2. Present client certificates for mTLS (needed for Midway SSO redirects)

Without these, navigating to any internal site results in auth failures.

## Solution

Two-part approach: **curl pre-auth** + **cookie injection**.

### How It Works

1. `mwinit` writes all auth cookies to `~/.midway/cookie` (AEA posture JWTs, Midway sessions, per-site SSO tokens)
2. `lib/auth-open.sh` uses **curl** to follow the full SSO redirect chain for the target URL — curl can do the mTLS handshake that WKWebView can't
3. curl captures all session cookies set along the way (including per-site `_rails-root_session`, `amzn_sso_token`, etc.)
4. All cookies are injected into a cmux browser panel via the socket protocol
5. The browser navigates to the URL — already fully authenticated, no redirects needed

### Why curl?

The SSO flow is: `site → midway-auth.amazon.com/SSO/redirect → site?id_token=...`

The middle step requires mTLS (client certificate presentation). curl uses the system keychain certs automatically. WKWebView can't. By doing the SSO dance in curl first, we capture the resulting session cookies and skip the redirect entirely in the browser.

## Usage

```bash
./lib/auth-open.sh https://phonetool.amazon.com/users/bssas
./lib/auth-open.sh https://code.amazon.com/packages/MyPackage
./lib/auth-open.sh https://taskei.amazon.dev/tasks/TASK-1234
```

### Prerequisites

- `mwinit` must have been run recently (cookies expire after a few hours)
- cmux must be running
- `python3`, `jq`, `nc`, `curl` must be available

## Automatic Cookie Refresh

A background daemon (`lib/cookie-refresh.sh`) handles cookie expiry automatically:

1. Launches at `agentSpawn` via `hooks/cmux-notify.sh` (same pattern as title generator)
2. Polls `~/.midway/cookie` mtime every 30 seconds
3. When the file changes (you ran `mwinit`), for each tracked browser surface:
   - Re-does the curl SSO flow to get fresh session cookies
   - Re-injects all cookies into the browser panel
   - Reloads the page
4. Prunes dead surfaces automatically

### No manual work required

Once a browser panel is opened with `lib/auth-open.sh`, it's registered for refresh. When you run `mwinit` (which you'd do anyway when cookies expire), the refresher picks it up within 30 seconds and re-auths all open panels.

### State files

All in `/tmp/kiro-cmux-$WORKSPACE_ID/`:

| File | Format | Purpose |
|---|---|---|
| `browser_surfaces` | `surface:N\tURL` per line | Tracked browser panels |
| `cookie_mtime` | Unix timestamp | Last processed cookie file mtime |
| `cookie_pid` | PID | Refresher process (for dedup) |

## Technical Details

### Cookie Domains

| Domain | Purpose |
|---|---|
| `.midway-auth.amazon.com` | Primary Midway auth, AEA posture JWT |
| `.auth.midway.aws.dev` | AWS dev domain AEA |
| `.auth.midway.aws.a2z.com` | A2Z domain AEA |
| `.auth.midway.amazon.dev` | Amazon dev domain AEA |
| `midway-auth.amazon.com` | Session + user identity |
| Per-site domains | SSO tokens + Rails session cookies |

### SSO Redirect Flow (what curl does)

```
1. GET https://phonetool.amazon.com/users/bssas
   → 302 to midway-auth.amazon.com/SSO/redirect?...

2. GET midway-auth.amazon.com/SSO/redirect?...  (with session cookies, mTLS)
   → 307 to phonetool.amazon.com/users/bssas?id_token=eyJ...
   → Sets fresh session + __Host-session cookies

3. GET phonetool.amazon.com/users/bssas?id_token=eyJ...
   → 302 to phonetool.amazon.com/users/bssas
   → Sets _rails-root_session, amzn_sso_token, amzn_sso_rfp cookies

4. All cookies captured in temp jar → injected into browser
```

### Socket Protocol

Cookie injection uses cmux's v2 JSON socket protocol for bulk set:

```json
{"id":"1","method":"browser.cookies.set","params":{"surface_id":"surface:N","cookies":[...]}}
```

### Tested Sites

| Site | Status |
|---|---|
| phonetool.amazon.com | ✅ Works |
| code.amazon.com | Needs testing |
| taskei.amazon.dev | ⚠️ SPA auth fails — auto-rewrites to issues.amazon.com |
| issues.amazon.com (SIM) | ✅ Works |
| w.amazon.com | Needs testing |

### SPA Limitations

Sites that use client-side JavaScript auth (React/Next.js SPAs like Taskei) may not work in WKWebView. The issue: the SPA's XHR/fetch calls to API subdomains trigger midway redirects that require mTLS, which WKWebView can't do. Server-rendered sites (SIM, Phonetool, Code Browser) work because all auth happens in the initial HTTP redirect chain that curl handles.

`_rewrite_url()` in `lib/auth.sh` maps broken SPA URLs to working alternatives:
- `taskei.amazon.dev/tasks/TASK-123` → `issues.amazon.com/issues/TASK-123`

### Limitations

- Requires `mwinit` to have been run (cookies must exist in `~/.midway/cookie`)
- Cookie refresh requires re-running `mwinit` — the refresher detects this automatically
- Sites not previously visited may need an initial `mwinit -s` for Sentry cookies

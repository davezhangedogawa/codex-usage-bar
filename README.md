# Codex Usage Bar

A tiny macOS menu bar utility that shows Codex and Claude usage remaining.

The menu bar item renders two stacked lines so all four values are visible at a glance:

```text
Codex  S79 W97   <- Codex: session / weekly remaining
Claude S82 W64   <- Claude: session / weekly remaining
```

`S` means the current session window (`300` minutes for Codex, `5` hours for Claude). `W` means the weekly window. Unavailable values show as `--`. Any value below 25% remaining turns orange, below 10% red. On a dark menu bar the text is white with a subtle dark shadow for visibility over translucent wallpaper; on a light menu bar it switches to dark text. Hover for exact details, click for the full menu.

## What It Reads

### Codex (local files only)

Codex writes current thread usage-window updates into the active rollout JSONL session file, whose path is stored in a state database. Newer Codex builds keep it at `~/.codex/sqlite/state_5.sqlite`, older ones at `~/.codex/state_5.sqlite`; the app tries both in that order.

The app reads recent thread `rollout_path` values from the state database, scans each rollout tail for `payload.rate_limits`, and displays the newest rate-limit event by timestamp. If the SQLite read fails, it falls back to scanning recent rollout files under `~/.codex/sessions`. The Codex path never touches the network and never modifies Codex data.

To avoid repeatedly loading large session files, the app scans from the tail of each recent rollout JSONL file and stops when it finds that file's newest `rate_limits` event.

### Claude (official usage endpoint)

Claude Code does not write its rate-limit percentages to local files, so the app reads the Claude Code OAuth token from the macOS Keychain (`Claude Code-credentials`, via `/usr/bin/security`) and calls Anthropic's usage endpoint every 3 minutes:

```text
GET https://api.anthropic.com/api/oauth/usage
```

This is the same source that powers Claude Code's `/usage` command, so the percentages match exactly. The call is read-only. On first launch macOS will show a Keychain permission prompt; choose "Always Allow" to avoid repeat prompts.

The stored token is refreshed by Claude Code itself. If you rarely run Claude Code the access token eventually expires and the Claude row shows `S-- W--`. Rather than opening a terminal, use the **Refresh Claude Login** menu item: it runs your own installed `claude` command once in the background (a one-word headless prompt), which makes the official client mint a fresh token and write it back to the Keychain. The bar then recovers on the next cycle. This uses your real Claude Code client, not a re-implementation, and costs a negligible sliver of usage. The menu item looks for `claude` in the usual install locations and, failing that, via a login shell.

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools
- Codex Desktop with local state files under `~/.codex`

The build script targets macOS 13.0 by default. You can override it explicitly:

```bash
MACOSX_DEPLOYMENT_TARGET=13.0 ./build.sh
```

## Build

```bash
git clone <repo-url>
cd codex-token-bar
./build.sh
```

The app bundle is created at:

```text
build/Codex Token Bar.app
```

## Start

```bash
./scripts/start.sh
```

You should see a compact two-line `Codex S79 W97 / Claude S82 W64` item in the macOS menu bar. Click it to see, for each of Codex and Claude:

- session remaining (`S`)
- weekly remaining (`W`)
- reset times
- data freshness and source

If the current Codex session has not written a fresh `rate_limits` payload yet, the menu bar keeps showing the last known good values and marks them as last known in the tooltip/menu. Expiry is judged per window: when a 5-hour session window has lapsed, only `S` falls back to `--` (the window has reset and there is no fresh event yet) while the still-valid weekly value keeps showing. A snapshot older than 6 hours is dropped entirely.

To stop it:

```bash
./scripts/stop.sh
```

The start script uses the normal macOS `.app` launch path. If LaunchServices fails on a beta build, it falls back to running the app executable directly in the background.

Logs are written to:

```text
~/Library/Logs/CodexUsageBar/
```

Normal successful refreshes are not logged. The app only logs lifecycle events and throttled read errors, and it truncates the runtime log when it reaches 1 MB.

## First-Principles Notes

The important question is not "how do we draw a counter?", but "where does the true remaining-usage signal live?"

For this local Codex desktop setup, the best local source is the current thread rollout JSONL, not the broad SQLite logs table. The logs table also records prompts and tool calls, which can contain stale copies of rate-limit JSON and make a naive scraper drift away from the Codex UI.

There is still one important limitation: Codex's local state files are not a public API contract. The app deliberately treats them as a practical, read-only approximation of the Codex UI.

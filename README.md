# Codex Usage Bar

A tiny macOS menu bar utility that shows Codex usage remaining from the current local Codex session.

The menu bar text is intentionally compact:

- `S`: remaining percentage in the current 300-minute session window
- `W`: remaining percentage in the weekly window, or `--` when Codex has not provided a weekly window

## What It Reads

Codex writes current thread usage-window updates into the active rollout JSONL session file, whose path is stored in:

```text
~/.codex/state_5.sqlite
```

The app reads recent thread `rollout_path` values from `state_5.sqlite`, scans each rollout tail for `payload.rate_limits`, and displays the newest rate-limit event by timestamp. It does not call the network and does not modify Codex data.

To avoid repeatedly loading large session files, the app scans from the tail of each recent rollout JSONL file and stops when it finds that file's newest `rate_limits` event.

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

You should see an `S 79% W 97%` style item in the macOS menu bar. Click it to see:

- current session remaining
- this week remaining
- used percentages
- reset times
- source database path

If the current Codex session has not written a fresh `rate_limits` payload yet, the menu bar keeps showing the last known good values and marks them as last known in the tooltip/menu. Expired last-known values are not displayed; on a fresh install or after the cached session window expires, it shows `S -- W --` until the first usable payload appears.

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

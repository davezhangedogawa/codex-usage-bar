#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/Codex Token Bar.app"
BINARY="$APP_DIR/Contents/MacOS/CodexTokenBar"
RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/codex-usage-bar"
PID_FILE="$RUN_DIR/codex-token-bar.pid"
LOG_DIR="$HOME/Library/Logs/CodexUsageBar"
LOG_FILE="$LOG_DIR/codex-token-bar.log"

mkdir -p "$RUN_DIR"
mkdir -p "$LOG_DIR"

if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE")"
  if kill -0 "$PID" 2>/dev/null; then
    echo "Codex Token Bar is already running (pid $PID)."
    exit 0
  fi
  rm -f "$PID_FILE"
fi

EXISTING_PID="$(pgrep -f "$BINARY" | head -n 1 || true)"
if [ -n "$EXISTING_PID" ]; then
  echo "$EXISTING_PID" > "$PID_FILE"
  echo "Codex Token Bar is already running (pid $EXISTING_PID)."
  exit 0
fi

if [ ! -x "$BINARY" ]; then
  "$ROOT_DIR/build.sh"
fi

if open "$APP_DIR"; then
  sleep 1
  pgrep -f "$BINARY" | head -n 1 > "$PID_FILE" || true
  echo "Started Codex Token Bar."
else
  nohup "$BINARY" > "$LOG_FILE" 2>&1 &
  echo "$!" > "$PID_FILE"
  echo "Started Codex Token Bar directly."
  echo "Log: $LOG_FILE"
fi

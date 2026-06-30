#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$ROOT_DIR/build/Codex Token Bar.app/Contents/MacOS/CodexTokenBar"
RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/codex-usage-bar"
PID_FILE="$RUN_DIR/codex-token-bar.pid"

if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE")"
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    rm -f "$PID_FILE"
    echo "Stopped Codex Token Bar."
    exit 0
  fi
  rm -f "$PID_FILE"
fi

PIDS="$(pgrep -f "$BINARY" || true)"
if [ -n "$PIDS" ]; then
  while IFS= read -r PID; do
    kill "$PID"
  done <<EOF
$PIDS
EOF
  echo "Stopped Codex Token Bar."
else
  echo "Codex Token Bar is not running."
fi

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/build/Codex Token Bar.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
MODULE_CACHE_DIR="$ROOT_DIR/build/ModuleCache"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
ARCH="$(/usr/bin/uname -m)"

mkdir -p "$MACOS_DIR"
mkdir -p "$MODULE_CACHE_DIR"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

/usr/bin/swiftc \
  -O \
  -parse-as-library \
  -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework Cocoa \
  "$ROOT_DIR/Sources/CodexTokenBar.swift" \
  -o "$MACOS_DIR/CodexTokenBar"

chmod +x "$MACOS_DIR/CodexTokenBar"

echo "Built: $APP_DIR"
echo "Deployment target: macOS $DEPLOYMENT_TARGET"

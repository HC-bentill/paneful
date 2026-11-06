#!/usr/bin/env bash
# Builds Paneful and wraps the binary into a runnable Paneful.app bundle.
# Usage: ./scripts/bundle.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/Paneful.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Paneful" "$APP/Contents/MacOS/Paneful"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so macOS keeps the Accessibility grant stable between launches.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo "Run with: open \"$APP\""

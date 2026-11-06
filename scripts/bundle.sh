#!/usr/bin/env bash
# Builds Paneful and wraps the binary into a runnable Paneful.app bundle.
# Usage: ./scripts/bundle.sh [debug|release]   (default: release)
#
# Signing: uses $PANEFUL_SIGN_IDENTITY if set, else the first "Apple Development" identity in the
# keychain, else ad-hoc. A real identity keeps the Accessibility grant valid across rebuilds; an
# ad-hoc signature changes every build, so macOS forgets the grant each time.
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
for f in MenuBarIcon.png MenuBarIcon@2x.png; do
  if [ -f "$ROOT/Resources/$f" ]; then cp "$ROOT/Resources/$f" "$APP/Contents/Resources/$f"; fi
done

IDENTITY="${PANEFUL_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1 || true)"
fi

if [ -n "$IDENTITY" ]; then
  codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  echo "Signed ad-hoc (re-grant Accessibility after each rebuild)"
fi

echo "Built $APP"
echo "Run with: open \"$APP\""

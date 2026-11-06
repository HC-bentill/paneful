#!/usr/bin/env bash
# Builds Paneful and wraps the binary into a runnable Paneful.app bundle.
# Usage: ./scripts/bundle.sh [debug|release]   (default: release)
#
# Environment (all optional):
#   PANEFUL_SIGN_IDENTITY  Signing identity. "-" = ad-hoc. Unset = the first "Apple Development" identity in
#                          the keychain, else ad-hoc. A real identity keeps the Accessibility grant valid across
#                          rebuilds; an ad-hoc signature changes every build, so macOS forgets the grant.
#                          "Developer ID Application: …" identities also get a secure timestamp (for notarizing).
#   PANEFUL_APP_DIR        Where to put Paneful.app (default: build). make-dmg.sh uses build/release so a
#                          release build never replaces the app you're testing.
#   PANEFUL_VERSION        Stamps CFBundleShortVersionString (and CFBundleVersion = git commit count).
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

OUT_DIR="${PANEFUL_APP_DIR:-$ROOT/build}"
APP="$OUT_DIR/Paneful.app"
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

if [ -n "${PANEFUL_VERSION:-}" ]; then
  PLIST="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${PANEFUL_VERSION#v}" "$PLIST"
  BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi

IDENTITY="${PANEFUL_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1 || true)"
fi

if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP"
  echo "Signed ad-hoc (re-grant Accessibility after each rebuild)"
else
  EXTRA=()
  case "$IDENTITY" in "Developer ID Application:"*) EXTRA=(--timestamp) ;; esac
  codesign --force --deep --options runtime ${EXTRA[@]+"${EXTRA[@]}"} --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
fi

echo "Built $APP"
echo "Run with: open \"$APP\""

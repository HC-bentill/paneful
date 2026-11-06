#!/usr/bin/env bash
# Builds a release Paneful.app and packages it as a drag-to-install DMG.
# Usage: ./scripts/make-dmg.sh [version]      (default: CFBundleShortVersionString from Resources/Info.plist)
#
# Output: build/Paneful-<version>.dmg, plus build/Paneful.dmg (same file). The stable name is what
#   https://github.com/HC-bentill/paneful/releases/latest/download/Paneful.dmg
# serves, so the landing page's download button never needs updating.
#
# Signing (environment, optional):
#   PANEFUL_SIGN_IDENTITY  A "Developer ID Application: …" identity. Unset = the first Developer ID identity in
#                          the keychain, else ad-hoc. Apple Development certificates are never used for public
#                          builds: Gatekeeper rejects them on other Macs anyway, and they embed your Apple ID email.
#   NOTARY_PROFILE         notarytool keychain profile (see `xcrun notarytool store-credentials`). With a
#                          Developer ID identity, the DMG is notarized and stapled.
#   NOTARY_KEYCHAIN        Keychain holding that profile (CI uses a temporary keychain).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")}"
VERSION="${VERSION#v}"

IDENTITY="${PANEFUL_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1 || true)"
fi
[ -n "$IDENTITY" ] || IDENTITY="-"

RELEASE_DIR="$ROOT/build/release"
PANEFUL_SIGN_IDENTITY="$IDENTITY" PANEFUL_APP_DIR="$RELEASE_DIR" PANEFUL_VERSION="$VERSION" \
  "$ROOT/scripts/bundle.sh" release
APP="$RELEASE_DIR/Paneful.app"

# Stage: the app plus an Applications shortcut to drag it onto.
WORK="$(mktemp -d)"
MNT="$WORK/mnt"
trap 'hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/stage"
cp -R "$APP" "$WORK/stage/"
ln -s /Applications "$WORK/stage/Applications"

# Read-write image first, so the volume can get Paneful's icon; then compress.
RW="$WORK/Paneful-rw.dmg"
hdiutil create -quiet -volname "Paneful" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov "$RW"
mkdir -p "$MNT"
hdiutil attach "$RW" -quiet -nobrowse -noverify -noautoopen -mountpoint "$MNT"
if [ -f "$ROOT/Resources/AppIcon.icns" ] && SETFILE="$(xcrun --find SetFile 2>/dev/null)"; then
  cp "$ROOT/Resources/AppIcon.icns" "$MNT/.VolumeIcon.icns"
  "$SETFILE" -a C "$MNT"
fi
hdiutil detach "$MNT" -quiet

OUT="$ROOT/build/Paneful-$VERSION.dmg"
hdiutil convert "$RW" -quiet -format UDZO -imagekey zlib-level=9 -ov -o "$OUT"

if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$OUT"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "Notarizing (this usually takes a few minutes)…"
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" \
      ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} --wait
    xcrun stapler staple "$OUT"
  else
    echo "Note: signed but NOT notarized (set NOTARY_PROFILE to notarize)."
  fi
else
  echo "Note: ad-hoc signed, not notarized. On first launch users must allow Paneful in"
  echo "      System Settings → Privacy & Security → Open Anyway."
fi

cp "$OUT" "$ROOT/build/Paneful.dmg"
echo "Built $OUT"
shasum -a 256 "$OUT"

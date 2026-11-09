#!/usr/bin/env bash
# Builds a release Paneful.app and packages it as a drag-to-install DMG.
# Usage: ./scripts/make-dmg.sh [version]      (default: CFBundleShortVersionString from Resources/Info.plist)
#
# Output: build/Paneful-<version>.dmg, plus build/Paneful.dmg (same file). The stable name is what
#   https://github.com/HC-bentill/paneful/releases/latest/download/Paneful.dmg
# serves, so the landing page's download button never needs updating.
#
# Signing (environment, optional):
#   PANEFUL_SIGN_IDENTITY  Identity to sign with. Unset = the first "Developer ID Application" identity in the
#                          keychain, else "Paneful Self-Signed" (made by scripts/make-signing-cert.sh), else
#                          ad-hoc. Apple Development certificates are never used for public builds: Gatekeeper
#                          rejects them on other Macs anyway, and they embed your Apple ID email.
#                          Why self-signed beats ad-hoc: the same certificate gives every release the same
#                          identity, so the Accessibility permission carries over to new versions. Ad-hoc builds
#                          get a new identity each time, and users must switch Paneful on again after updating.
#   PANEFUL_KEYCHAIN       Keychain holding that identity (CI uses a temporary keychain).
#   NOTARY_PROFILE         notarytool keychain profile (see `xcrun notarytool store-credentials`). With a
#                          Developer ID identity, the DMG is notarized and stapled.
#   NOTARY_KEYCHAIN        Keychain holding that profile (CI uses a temporary keychain).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")}"
VERSION="${VERSION#v}"

IDENTITY="${PANEFUL_SIGN_IDENTITY:-}"
KEYCHAIN_ARG=()
if [ -n "${PANEFUL_KEYCHAIN:-}" ]; then KEYCHAIN_ARG=("$PANEFUL_KEYCHAIN"); fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -p codesigning -v ${KEYCHAIN_ARG[@]+"${KEYCHAIN_ARG[@]}"} 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1 || true)"
fi
if [ -z "$IDENTITY" ]; then
  # Self-signed certificates aren't "valid" (no trusted root), so look without -v. codesign still signs with them.
  IDENTITY="$(security find-identity -p codesigning ${KEYCHAIN_ARG[@]+"${KEYCHAIN_ARG[@]}"} 2>/dev/null \
    | sed -n 's/.*"\(Paneful Self-Signed\)".*/\1/p' | head -n 1 || true)"
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

case "$IDENTITY" in
  "Developer ID Application:"*) DEVELOPER_ID=1 ;;
  *) DEVELOPER_ID=0 ;;
esac

if [ "$DEVELOPER_ID" = 1 ]; then
  codesign --force --timestamp --sign "$IDENTITY" ${PANEFUL_KEYCHAIN:+--keychain "$PANEFUL_KEYCHAIN"} "$OUT"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "Notarizing (this usually takes a few minutes)…"
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" \
      ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} --wait
    xcrun stapler staple "$OUT"
  else
    echo "Note: signed but NOT notarized (set NOTARY_PROFILE to notarize)."
  fi
elif [ "$IDENTITY" != "-" ]; then
  echo "Note: signed with \"$IDENTITY\" (the Accessibility permission carries over between releases), not"
  echo "      notarized. On first launch users must allow Paneful in System Settings → Privacy & Security → Open Anyway."
else
  echo "Note: ad-hoc signed, not notarized. On first launch users must allow Paneful in"
  echo "      System Settings → Privacy & Security → Open Anyway. After each update they must switch Paneful on"
  echo "      again under Accessibility (Paneful clears the old entry itself). See scripts/make-signing-cert.sh."
fi

cp "$OUT" "$ROOT/build/Paneful.dmg"
echo "Built $OUT"
shasum -a 256 "$OUT"

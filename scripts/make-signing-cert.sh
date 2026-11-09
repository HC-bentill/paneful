#!/usr/bin/env bash
# Creates Paneful's self-signed code-signing certificate. Run it ONCE, keep the output safe, and reuse it for
# every release.
#
# Why: macOS ties the Accessibility permission to the app's code signature. An ad-hoc signature is different
# for every build, so after each update users had to switch Paneful on again. A build signed with the same
# certificate every time keeps the same identity ("identifier io.github.hc-bentill.paneful and certificate
# leaf = <this certificate>"), so the permission carries over to new versions. It doesn't replace a Developer ID:
# Gatekeeper still asks users to confirm the first launch (Open Anyway), exactly as with ad-hoc builds.
#
# Usage: ./scripts/make-signing-cert.sh [--import]
#   Writes build/signing/Paneful-Self-Signed.p12 (+ a random password) and prints what to put in the
#   GitHub repository secrets SELF_SIGNED_P12 and SELF_SIGNED_P12_PASSWORD.
#   --import also adds it to your login keychain, so ./scripts/make-dmg.sh uses it locally.
#
# Don't regenerate it later: a new certificate is a new identity, and every user would have to switch
# Paneful on again once.
set -euo pipefail

NAME="Paneful Self-Signed"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/signing"
P12="$OUT/Paneful-Self-Signed.p12"

if [ -f "$P12" ]; then
  echo "$P12 already exists. Reuse it (see the top of this script for why). Delete it first to start over."
  exit 1
fi

mkdir -p "$OUT"
chmod 700 "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASSWORD="$(openssl rand -base64 24)"
# -legacy: macOS's `security import` can't read OpenSSL 3's default p12 encryption.
openssl pkcs12 -export -legacy -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$P12" -passout "pass:$PASSWORD" 2>/dev/null \
  || openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
       -out "$P12" -passout "pass:$PASSWORD"
printf '%s' "$PASSWORD" > "$OUT/Paneful-Self-Signed.password"
chmod 600 "$P12" "$OUT/Paneful-Self-Signed.password"

echo "Created $P12"
echo "SHA-1: $(openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2)"

if [ "${1:-}" = "--import" ]; then
  security import "$P12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASSWORD" -T /usr/bin/codesign
  echo "Imported \"$NAME\" into your login keychain (make-dmg.sh will use it)."
fi

cat <<EOF

Next:
  1. Back up build/signing/ somewhere safe (a password manager). build/ is git-ignored, so it's never committed.
  2. Add two repository secrets (GitHub → Settings → Secrets and variables → Actions):
       SELF_SIGNED_P12           base64 of the .p12:   base64 -i "$P12" | pbcopy
       SELF_SIGNED_P12_PASSWORD  the password:         pbcopy < "$OUT/Paneful-Self-Signed.password"
  3. The next tagged release is signed with it. Users switch Paneful on one last time after updating to
     that release; from then on updates keep the permission.
EOF

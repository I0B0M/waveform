#!/bin/bash
# Build Waveform.app with SwiftPM + Command Line Tools (no Xcode needed).
#
# Usage:
#   Scripts/build-app.sh [debug|release]
#
# Signing: ad-hoc by default. Ad-hoc identity changes on every rebuild, which
# makes macOS forget the Microphone/Accessibility grants each time. For daily
# use, create a self-signed code-signing certificate once (Keychain Access →
# Certificate Assistant → Create a Certificate… → type "Code Signing", name it
# e.g. "Waveform Dev") and build with:
#   CODESIGN_IDENTITY="Waveform Dev" Scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
IDENTITY="${CODESIGN_IDENTITY:-}"

# First run on a new machine: create a local self-signed signing identity so
# macOS permission grants (Microphone/Accessibility) survive rebuilds.
# Without one, every rebuild looks like a brand-new app to macOS.
ensure_cert() {
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Waveform Dev"; then
    return
  fi
  echo "Creating local 'Waveform Dev' signing certificate (one time)…"
  local tmp; tmp=$(mktemp -d)
  openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -days 3650 -nodes -subj "/CN=Waveform Dev" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
  openssl pkcs12 -export -out "$tmp/dev.p12" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -name "Waveform Dev" -passout pass:waveform 2>/dev/null
  security import "$tmp/dev.p12" -k ~/Library/Keychains/login.keychain-db \
    -P waveform -T /usr/bin/codesign >/dev/null
  security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db \
    "$tmp/cert.pem" 2>/dev/null || true
  rm -rf "$tmp"
}

if [ -z "$IDENTITY" ]; then
  ensure_cert
  # Prefer any real codesigning identity over ad-hoc: ad-hoc identity changes
  # every rebuild, and macOS then silently drops the Accessibility/Microphone
  # grants. See README for the one-time self-signed certificate setup.
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NR==1 {print $2}')
  IDENTITY="${IDENTITY:--}"
fi

# Only the app product — the test runner uses @testable and is debug-only.
swift build -c "$CONFIG" --product Waveform

APP="build/Waveform.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "Support/Info.plist" "$APP/Contents/Info.plist"
cp ".build/$CONFIG/Waveform" "$APP/Contents/MacOS/Waveform"

codesign --force --sign "$IDENTITY" --identifier com.ibrahim.waveform "$APP"

echo "Built $APP (config: $CONFIG, identity: $IDENTITY)"
echo "Run with: open $APP"

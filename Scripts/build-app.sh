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
CERT_NAME="Waveform Dev"

ensure_cert() {
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    return
  fi
  echo "Creating local \"$CERT_NAME\" signing certificate (one time)…"
  local tmp; tmp=$(mktemp -d)
  openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -days 3650 -nodes -subj "/CN=$CERT_NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
  openssl pkcs12 -export -out "$tmp/dev.p12" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -name "$CERT_NAME" -passout pass:waveform 2>/dev/null
  security import "$tmp/dev.p12" -k ~/Library/Keychains/login.keychain-db \
    -P waveform -T /usr/bin/codesign >/dev/null
  security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db \
    "$tmp/cert.pem" 2>/dev/null || true
  rm -rf "$tmp"
}

if [ -z "$IDENTITY" ]; then
  ensure_cert
  # Pin to OUR certificate by name. Never "first identity found": the signing
  # identity is what macOS ties Microphone/Accessibility grants to, so picking
  # a different cert on a later build silently revokes every permission.
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    IDENTITY="$CERT_NAME"
  else
    IDENTITY="-"
  fi
fi

# Only the app product — the test runner uses @testable and is debug-only.
swift build -c "$CONFIG" --product Waveform

APP="build/Waveform.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "Support/Info.plist" "$APP/Contents/Info.plist"
cp ".build/$CONFIG/Waveform" "$APP/Contents/MacOS/Waveform"

# App icon: regenerate whenever the drawing is newer than the built .icns.
if [ ! -f Support/AppIcon.icns ] || [ Sources/WaveformCore/Branding/DiscoIconView.swift -nt Support/AppIcon.icns ]; then
  echo "Regenerating app icon…"
  ICONSET=$(mktemp -d)/Waveform.iconset
  ".build/$CONFIG/Waveform" --export-iconset "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o Support/AppIcon.icns
fi
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "$IDENTITY" --identifier com.ibrahim.waveform "$APP"

# Keep an installed copy in sync automatically. Two copies of a menu-bar app
# is a foot-gun — you fix a bug, then launch the stale one and see no change.
LS_REGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -d "/Applications/Waveform.app" ] || [ "${INSTALL:-0}" = "1" ]; then
  if ditto "$APP" "/Applications/Waveform.app" 2>/dev/null; then
    echo "Installed to /Applications/Waveform.app"
    [ -x "$LS_REGISTER" ] && "$LS_REGISTER" -f "/Applications/Waveform.app" >/dev/null 2>&1
  else
    echo "Could not write /Applications — copy it manually in Finder."
  fi
fi
# Nudge LaunchServices so Finder picks up a changed icon immediately.
[ -x "$LS_REGISTER" ] && "$LS_REGISTER" -f "$APP" >/dev/null 2>&1

echo "Built $APP (config: $CONFIG, identity: $IDENTITY)"
echo "Run with: open $APP"

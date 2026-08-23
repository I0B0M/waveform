#!/bin/bash
# Build Discotype.app with SwiftPM + Command Line Tools (no Xcode needed).
#
# Usage:
#   Scripts/build-app.sh [debug|release]
#
# Signing: ad-hoc by default. Ad-hoc identity changes on every rebuild, which
# makes macOS forget the Microphone/Accessibility grants each time. For daily
# use, create a self-signed code-signing certificate once (Keychain Access →
# Certificate Assistant → Create a Certificate… → type "Code Signing", name it
# e.g. "Discotype Dev") and build with:
#   CODESIGN_IDENTITY="Discotype Dev" Scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # Prefer any real codesigning identity over ad-hoc: ad-hoc identity changes
  # every rebuild, and macOS then silently drops the Accessibility/Microphone
  # grants. See README for the one-time self-signed certificate setup.
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NR==1 {print $2}')
  IDENTITY="${IDENTITY:--}"
fi

# Only the app product — the test runner uses @testable and is debug-only.
swift build -c "$CONFIG" --product Discotype

APP="build/Discotype.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "Support/Info.plist" "$APP/Contents/Info.plist"
cp ".build/$CONFIG/Discotype" "$APP/Contents/MacOS/Discotype"

codesign --force --sign "$IDENTITY" --identifier com.ibrahim.discotype "$APP"

echo "Built $APP (config: $CONFIG, identity: $IDENTITY)"
echo "Run with: open $APP"

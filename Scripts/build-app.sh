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
IDENTITY="${CODESIGN_IDENTITY:--}"

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

#!/bin/bash
# Build a double-clickable Waveform.dmg for sharing.
#
#   Scripts/release.sh
#
# The disk image contains the app plus an Applications shortcut, so installing
# is drag-and-drop. Colleagues need macOS 26 on Apple silicon and nothing else
# installed — no Xcode, no toolchain.
#
# GATEKEEPER: the app is signed with a locally-generated certificate, not an
# Apple Developer ID (that needs a paid account). macOS will therefore warn on
# first launch. The fix is one right-click, and it is documented in the README
# and printed below. Notarizing later removes the warning entirely and needs no
# code changes — only a real Developer ID to sign with.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
DMG="dist/Waveform-$VERSION.dmg"

Scripts/build-app.sh release

STAGE=$(mktemp -d)/Waveform
mkdir -p "$STAGE" dist
cp -R build/Waveform.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/READ ME FIRST.txt" <<'NOTE'
Waveform — local-first dictation for macOS 26

INSTALL
  1. Drag Waveform.app onto the Applications shortcut here.
  2. In Applications, RIGHT-CLICK Waveform and choose "Open", then confirm.
     (Only needed once. macOS shows a warning because this build is signed
     with a self-signed certificate rather than a paid Apple Developer ID —
     nothing about the app is different.)
  3. Press the hotkey once and grant Microphone, then Accessibility
     (System Settings opens for you; Accessibility needs a manual toggle).
     Accessibility is what lets dictated text land in other apps.

USING IT
  Default hotkey is Cmd-X (it replaces Cut while running — change it in
  Settings: Option-Space, Ctrl-Option-D, F19, or double-tap Control).
  Speak, stop talking, and the cleaned text appears at your cursor.
  On the HUD: sparkles = organize the text first, checkmark = insert as
  spoken, x = discard.

Everything runs on this Mac. No account, no cloud, no audio ever leaves it.
NOTE

rm -f "$DMG"
hdiutil create -volname "Waveform $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO -quiet "$DMG"
rm -rf "$(dirname "$STAGE")"

SIZE=$(du -h "$DMG" | cut -f1)
echo ""
echo "Built $DMG ($SIZE)"
echo ""
echo "Send that file. On first launch the recipient must right-click the app"
echo "and choose Open (self-signed build, not notarized) — after that it"
echo "behaves like any other app."

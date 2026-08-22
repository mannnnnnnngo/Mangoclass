#!/bin/bash
# Builds a mangoclass disk image you can hand to someone who doesn't have
# Apple's developer tools installed. Made by Mingyu.
#
#   ./package.sh        writes dist/mangoclass-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")"

APP="mangoclass.app"
VERSION="$(tr -d '[:space:]' < VERSION)"   # same source of truth build.sh stamps from
DMG="dist/mangoclass-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

./build.sh --universal

mkdir -p dist
rm -f "$DMG"

cp -R "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Read Me First.txt" <<'EOS'
mangoclass — a menu bar countdown for your school day
Made by Mingyu

INSTALLING

1. Drag mangoclass onto the Applications folder in this window.
2. Open your Applications folder, RIGHT-CLICK mangoclass, and choose Open.
   Then press Open in the dialog that appears.

   Step 2 matters. Double-clicking the first time gives you a warning that
   mangoclass "cannot be opened because it is from an unidentified developer"
   with no way past it — the app isn't signed with a paid Apple developer
   account. Right-click → Open is Apple's built-in way around that, and you
   only have to do it once. Afterwards it opens normally.

   On macOS 15 and newer the warning may instead say the app "is not trusted".
   If Open isn't offered, go to System Settings → Privacy & Security, scroll
   down, and press "Open Anyway" next to mangoclass.

USING IT

There is no window and no Dock icon — mangoclass lives in the menu bar at the
top-right of the screen, showing the class you're in and the time left.

  Left-click   the countdown panel: current class, progress, what's next
  Right-click  a short menu with Edit Schedules and Quit

First thing to do is put in your own classes: right-click → Edit Schedules.

PERMISSIONS

mangoclass asks for nothing at launch and sends nothing anywhere. Two things
may prompt you later, both optional:

  Login Items    turning on Settings → General → "Open at login" asks macOS to
                 start it automatically. Approve it in System Settings →
                 General → Login Items if it doesn't stick.
  Files          importing a schedule from a picture opens a file panel. If the
                 picture is in Desktop, Documents or Downloads, macOS asks once
                 for access to that folder. Pictures are read on your Mac using
                 Apple's Vision framework — nothing is uploaded.

UPDATES

mangoclass checks for a newer version every time it opens. When there is one it
says so, downloads it in the background, and offers to install it — you press a
button and it replaces itself and reopens. Your schedules are never touched.

Settings -> Updates has the version number, a Check for Updates button, and
switches for all of that if you would rather do it yourself.

UNINSTALLING

Drag mangoclass out of Applications and into the Trash. Your schedules stay in
~/Library/Application Support/ClassSchedule — delete that folder too for a
completely clean slate.
EOS

hdiutil create -volname "mangoclass $VERSION" \
    -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null

# The checksum the app verifies a download against before it installs it. release.sh
# copies this into updates/latest.json.
shasum -a 256 "$DMG" | awk '{print $1}' > "$DMG.sha256"

echo "Built $(pwd)/$DMG"
echo "  version  $VERSION"
echo "  sha256   $(cat "$DMG.sha256")"
echo "Anyone on macOS 14 or newer can install from this — no developer tools needed."

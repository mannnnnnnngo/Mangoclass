#!/bin/bash
# mangoclass installer — builds the app and puts it in /Applications.
# Made by Mingyu.
#
#   ./install.sh                install to /Applications
#   ./install.sh --user         install to ~/Applications (no password needed)
#   ./install.sh --latest       download the newest released version instead of building
#   ./install.sh --uninstall    remove the app (your schedules are kept)
set -euo pipefail

cd "$(dirname "$0")"

APP="mangoclass.app"
DEST="/Applications"
DATA="$HOME/Library/Application Support/ClassSchedule"
UPDATES="$DATA/Updates"
REPO="mannnnnnnngo/Mangoclass"
MANIFEST_URL="https://raw.githubusercontent.com/$REPO/main/updates/latest.json"
VERSION="$(tr -d '[:space:]' < VERSION)"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

for arg in "$@"; do
    case "$arg" in
        --user)      DEST="$HOME/Applications" ;;
        --latest)    LATEST=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help)   sed -n '2,8s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *)           fail "unknown option: $arg" ;;
    esac
done

# ---------------------------------------------------------------- update manifest
#
# The same little JSON file the app itself reads on every launch. Fetching it here means
# a fresh install already knows where it stands — and the app has it cached before its
# first check ever runs, so it works on a Mac that's offline the first time it opens.

MANIFEST=""

fetch_manifest() {
    MANIFEST=$(curl -fsSL --max-time 10 "$MANIFEST_URL" 2>/dev/null || true)
}

# Pulls one "key": "value" out of the manifest. Every key in it is unique, so this is
# enough and saves depending on jq being installed.
json_string() {
    printf '%s' "$MANIFEST" | tr -d '\n' \
        | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

# a > b ? Compares 0.1.10 against 0.2.0 properly, which sort -V also does but isn't
# on every Mac.
version_gt() {
    [ "$(echo "$1" | awk -F. '{printf "%d", $1 * 10000 + $2 * 100 + $3}')" \
      -gt "$(echo "$2" | awk -F. '{printf "%d", $1 * 10000 + $2 * 100 + $3}')" ]
}

cache_manifest() {
    [ -n "$MANIFEST" ] || return 0
    mkdir -p "$UPDATES"
    printf '%s\n' "$MANIFEST" > "$UPDATES/manifest.json"
}

# ---------------------------------------------------------------- uninstall

if [ "${UNINSTALL:-0}" = "1" ]; then
    for dir in /Applications "$HOME/Applications"; do
        if [ -d "$dir/$APP" ]; then
            osascript -e 'tell application id "com.mango.classschedule" to quit' 2>/dev/null || true
            pkill -f "$dir/$APP" 2>/dev/null || true
            rm -rf "$dir/$APP" 2>/dev/null || sudo rm -rf "$dir/$APP"
            echo "Removed $dir/$APP"
        fi
    done
    echo
    echo "Your schedules are still at:"
    echo "  $DATA"
    echo "Delete that folder too if you want a completely clean slate."
    exit 0
fi

# ---------------------------------------------------------------- checks

MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 14 ] || fail "needs macOS 14 (Sonoma) or newer — this Mac is on $(sw_vers -productVersion)."

# ---------------------------------------------------------------- placing the app

# Copies a built mangoclass.app into DEST, quitting whatever is running there first.
place_app() {
    local source=$1
    mkdir -p "$DEST"

    if [ -d "$DEST/$APP" ]; then
        echo "Replacing the copy already in ${DEST}…"
        osascript -e 'tell application id "com.mango.classschedule" to quit' 2>/dev/null || true
        sleep 1
    fi

    if [ -w "$DEST" ]; then
        rm -rf "$DEST/$APP"
        cp -R "$source" "$DEST/$APP"
    else
        echo "$DEST needs an administrator password."
        sudo rm -rf "$DEST/$APP"
        sudo cp -R "$source" "$DEST/$APP"
        sudo chown -R "$(id -u):$(id -g)" "$DEST/$APP"
    fi
}

# ---------------------------------------------------------------- --latest
#
# Installs the newest published .dmg rather than building this folder. Useful when the
# source here is older than what's been released, and it's the same file the app
# downloads for itself when it updates.

if [ "${LATEST:-0}" = "1" ]; then
    bold "Looking up the newest released version…"
    fetch_manifest
    [ -n "$MANIFEST" ] || fail "couldn't reach $MANIFEST_URL — check the network, or run ./install.sh to build from this folder instead."

    RELEASED=$(json_string version)
    DOWNLOAD=$(json_string downloadURL)
    WANT_SHA=$(json_string sha256)
    [ -n "$RELEASED" ] && [ -n "$DOWNLOAD" ] || fail "the update information at $MANIFEST_URL didn't have a version and a download in it."

    echo "Newest release is $RELEASED (this folder is $VERSION)."
    mkdir -p "$UPDATES"
    DMG="$UPDATES/mangoclass-$RELEASED.dmg"

    echo "Downloading…"
    curl -fL --progress-bar -o "$DMG" "$DOWNLOAD" || fail "the download failed."

    if [ -n "$WANT_SHA" ]; then
        GOT_SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
        [ "$GOT_SHA" = "$WANT_SHA" ] || { rm -f "$DMG"; fail "the download didn't match its checksum, so nothing was installed."; }
        echo "Checksum matches."
    fi

    MOUNT=$(mktemp -d /tmp/mangoclass-install.XXXXXX)
    hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" > /dev/null \
        || fail "couldn't open the disk image."
    [ -d "$MOUNT/$APP" ] || { hdiutil detach "$MOUNT" -quiet; fail "there's no $APP inside the disk image."; }

    place_app "$MOUNT/$APP"
    hdiutil detach "$MOUNT" -quiet -force > /dev/null 2>&1 || true
    rmdir "$MOUNT" 2>/dev/null || true

    cache_manifest
    xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true
    touch "$DEST/$APP"

    bold "Installed mangoclass $RELEASED to $DEST/$APP"
    open "$DEST/$APP"
    exit 0
fi

# ---------------------------------------------------------------- build

if ! command -v swiftc > /dev/null; then
    bold "Apple's command line tools are needed to build the app."
    echo "A system dialog will now ask to install them. Run this script again once it finishes."
    echo "Or skip building altogether: ./install.sh --latest downloads the released version."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

bold "Building mangoclass $VERSION…"
./build.sh --universal

# ---------------------------------------------------------------- install

place_app "$APP"

# The app is signed ad-hoc rather than by a paid developer account, so clear the
# download quarantine flag to save the "unidentified developer" round trip.
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true
touch "$DEST/$APP"   # nudge LaunchServices so Finder picks up the icon

# ---------------------------------------------------------------- prime
#
# Everything the app needs, in place before it first opens: its folder, and the update
# information cached so the very first launch already knows whether it's current —
# even on a Mac that has no network the first time it runs.

mkdir -p "$UPDATES"
fetch_manifest
cache_manifest

RELEASED=$(json_string version)
if [ -n "$RELEASED" ] && version_gt "$RELEASED" "$VERSION"; then
    echo
    bold "Heads up: $RELEASED has been released, and this folder is $VERSION."
    echo "  ./install.sh --latest downloads and installs it, or 'git pull' and run this again."
    echo "  The app will offer it to you on its own anyway, next time it opens."
fi

bold "Installed mangoclass $VERSION to $DEST/$APP"
open "$DEST/$APP"

cat <<'EOS'

mangoclass is running — look for the countdown in your menu bar, at the
top-right of the screen. If you don't see it, the bar may be full: quit
another menu bar app, or widen it by hiding one.

Next steps
  1. Left-click the menu bar item for the countdown panel.
  2. Right-click it → Edit Schedules to put in your own classes.
  3. Settings → Calendar → "Set today to" so the app knows which day it is.
  4. Settings → General → Open at login, so it comes back after a restart.

Updates take care of themselves: mangoclass checks GitHub every time it opens,
downloads a newer version in the background, and offers to install it. Your
schedules are never touched by any of that. Settings → Updates has the version
number and the switches.

The full walkthrough is in the README.
EOS

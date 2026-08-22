#!/bin/bash
# Builds mangoclass.app next to this script.
#
#   ./build.sh              arm64 only — fast, for working on it
#   ./build.sh --universal  arm64 + x86_64 — what gets handed to other people
set -euo pipefail

cd "$(dirname "$0")"

APP="mangoclass.app"
BIN="ClassSchedule"
DEPLOYMENT_TARGET="14.0"

# ---------------------------------------------------------------- version
#
# VERSION is the single source of truth. Info.plist and the built bundle are both
# stamped from it, so the number the app shows, the number in the .dmg filename and
# the number in updates/latest.json can never drift apart. ./release.sh changes it.

VERSION="$(tr -d '[:space:]' < VERSION)"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: VERSION must look like 0.1.0 — found '$VERSION'" >&2
    exit 1
fi

# CFBundleVersion has to only ever go up. major*10000 + minor*100 + patch does that,
# and stays readable: 0.1.0 → 100, 0.1.1 → 101, 0.2.0 → 200.
BUILD=$(echo "$VERSION" | awk -F. '{printf "%d", $1 * 10000 + $2 * 100 + $3}')

UNIVERSAL=0
[ "${1:-}" = "--universal" ] && UNIVERSAL=1

if ! command -v swiftc > /dev/null; then
    echo "error: swiftc not found. Install Apple's command line tools first:" >&2
    echo "         xcode-select --install" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Regenerate the icon whenever the drawing is newer than the built .icns.
if [ ! -f Icon/AppIcon.icns ] || [ Icon/mangoclass.png -nt Icon/AppIcon.icns ]; then
    echo "Generating icon…"
    swift Tools/make_icon.swift
fi

compile() { # arch, output path
    swiftc -O \
        -target "$1-apple-macos$DEPLOYMENT_TARGET" \
        -o "$2" \
        Sources/*.swift
}

if [ "$UNIVERSAL" = "1" ]; then
    # swiftc builds one architecture at a time, so build both and lipo them together.
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    for ARCH in arm64 x86_64; do
        echo "Compiling ($ARCH)…"
        compile "$ARCH" "$TMP/$BIN-$ARCH"
    done
    lipo -create -output "$APP/Contents/MacOS/$BIN" "$TMP/$BIN-arm64" "$TMP/$BIN-x86_64"
else
    echo "Compiling…"
    compile "$(uname -m)" "$APP/Contents/MacOS/$BIN"
fi

cp Info.plist "$APP/Contents/Info.plist"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Stamp the version into the bundle, and back into the source Info.plist if someone
# edited VERSION by hand — one number, kept in both places.
plist() { /usr/libexec/PlistBuddy -c "$1" "$2"; }
plist "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
plist "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
if [ "$(plist 'Print :CFBundleShortVersionString' Info.plist)" != "$VERSION" ]; then
    plist "Set :CFBundleShortVersionString $VERSION" Info.plist
    plist "Set :CFBundleVersion $BUILD" Info.plist
    echo "Info.plist updated to $VERSION"
fi

# Any fonts dropped into Fonts/ get bundled and registered at launch.
if compgen -G "Fonts/*.[ot]t[fc]" > /dev/null; then
    mkdir -p "$APP/Contents/Resources/Fonts"
    cp Fonts/*.[ot]t[fc] "$APP/Contents/Resources/Fonts/"
    echo "Bundled $(ls Fonts/*.[ot]t[fc] | wc -l | tr -d ' ') font file(s)"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature so macOS treats it as a stable, trusted-by-you app.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $(pwd)/$APP — version $VERSION (build $BUILD, $(lipo -archs "$APP/Contents/MacOS/$BIN"))"

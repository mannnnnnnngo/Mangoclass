#!/bin/bash
# Ships a new version of mangoclass. Made by Mingyu.
#
#   ./release.sh patch              0.1.0 -> 0.1.1   a fix or a small change
#   ./release.sh minor              0.1.0 -> 0.2.0   a proper upgrade
#   ./release.sh major              0.1.0 -> 1.0.0
#   ./release.sh 0.4.2              straight to a number you pick
#
#   --notes "what changed"          the text the app shows people (default: your commits)
#   --publish                       actually push it and create the GitHub release
#   --dry-run                       work out the new number and stop
#   --publish-only                  don't build — publish the .dmg that's already in dist/
#
# Without --publish nothing leaves this Mac: it builds the .dmg, writes the manifest,
# and prints the commands to run when you're happy with it.
set -euo pipefail

cd "$(dirname "$0")"

REPO="mannnnnnnngo/Mangoclass"
CURRENT="$(tr -d '[:space:]' < VERSION)"

NOTES=""
PUBLISH=0
DRYRUN=0
SKIP_BUILD=0
BUMP=""

# ---------------------------------------------------------------- arguments

while [ $# -gt 0 ]; do
    case "$1" in
        patch|minor|major)  BUMP="$1" ;;
        --notes)            NOTES="${2:-}"; shift ;;
        --publish)          PUBLISH=1 ;;
        --dry-run)          DRYRUN=1 ;;
        --publish-only)     PUBLISH=1; SKIP_BUILD=1 ;;
        -h|--help)          sed -n '2,18s/^# \{0,1\}//p' "$0"; exit 0 ;;
        [0-9]*.[0-9]*.[0-9]*) BUMP="$1" ;;
        *)                  echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

[ -n "$BUMP" ] || { echo "say what kind of release: patch, minor, major, or a number like 0.2.0" >&2; exit 1; }

# ---------------------------------------------------------------- new number

IFS=. read -r MA MI PA <<< "$CURRENT"
case "$BUMP" in
    patch) VERSION="$MA.$MI.$((PA + 1))" ;;
    minor) VERSION="$MA.$((MI + 1)).0" ;;
    major) VERSION="$((MA + 1)).0.0" ;;
    *)     VERSION="$BUMP" ;;
esac

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: '$VERSION' isn't a version number" >&2
    exit 1
fi

# Versions only ever go up — the app compares them, and a lower one would look like
# a downgrade to everyone who already has the higher one.
BUILD=$(echo "$VERSION" | awk -F. '{printf "%d", $1 * 10000 + $2 * 100 + $3}')
OLD_BUILD=$(echo "$CURRENT" | awk -F. '{printf "%d", $1 * 10000 + $2 * 100 + $3}')
# --publish-only publishes a build that already happened, so VERSION has already been
# written and asking for that same number again is the expected thing, not a mistake.
if [ "$SKIP_BUILD" = "1" ]; then
    if [ "$BUILD" -lt "$OLD_BUILD" ]; then
        echo "error: $VERSION is older than $CURRENT, which is what's built" >&2
        exit 1
    fi
elif [ "$BUILD" -le "$OLD_BUILD" ]; then
    echo "error: $VERSION isn't newer than $CURRENT" >&2
    exit 1
fi

[ "$SKIP_BUILD" = "1" ] && echo "mangoclass $VERSION" || echo "mangoclass $CURRENT → $VERSION"
[ "$DRYRUN" = "1" ] && exit 0

# ---------------------------------------------------------------- notes

if [ -z "$NOTES" ]; then
    LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
    if [ -n "$LAST_TAG" ]; then
        NOTES=$(git log --no-merges --pretty=format:'· %s' "$LAST_TAG"..HEAD | head -12)
    else
        NOTES=$(git log --no-merges --pretty=format:'· %s' -5)
    fi
    [ -n "$NOTES" ] || NOTES="Small fixes and improvements."
fi

# ---------------------------------------------------------------- build

DMG="dist/mangoclass-$VERSION.dmg"

if [ "$SKIP_BUILD" = "1" ]; then
    [ -f "$DMG" ] || { echo "error: $DMG isn't there — build it first, without --publish-only" >&2; exit 1; }
    echo "Using the $DMG that's already built."
else
    echo "$VERSION" > VERSION
    ./package.sh
fi

[ -f "$DMG" ] || { echo "error: $DMG wasn't built" >&2; exit 1; }
SHA=$(cat "$DMG.sha256")

# ---------------------------------------------------------------- manifest
#
# This is the file every copy of the app reads on launch. Writing it is what makes a
# release visible to everyone — until it's pushed, nothing has changed for anybody.

# Release notes are free text and end up inside a JSON string, so quotes, backslashes
# and the line breaks between commits all have to be escaped.
json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\r'/}
    s=${s//$'\t'/\\t}
    s=${s//$'\n'/\\n}
    printf '%s' "$s"
}

mkdir -p updates
cat > updates/latest.json <<EOS
{
  "version": "$VERSION",
  "build": $BUILD,
  "publishedAt": "$(date +%Y-%m-%d)",
  "minimumSystemVersion": "14.0",
  "notes": "$(json_escape "$NOTES")",
  "downloadURL": "https://github.com/$REPO/releases/download/v$VERSION/mangoclass-$VERSION.dmg",
  "sha256": "$SHA",
  "releasePage": "https://github.com/$REPO/releases/tag/v$VERSION"
}
EOS

echo
echo "Wrote updates/latest.json:"
cat updates/latest.json
echo

# ---------------------------------------------------------------- publish

if [ "$PUBLISH" != "1" ]; then
    cat <<EOS

Nothing has been pushed. When you're happy with it:

  git add VERSION Info.plist updates/latest.json
  git commit -m "Release $VERSION"
  git tag v$VERSION
  git push origin main --tags
  gh release create v$VERSION "$DMG" --title "mangoclass $VERSION" --notes "$NOTES"

Or run this again with --publish and it'll do all of that for you.
EOS
    exit 0
fi

command -v gh > /dev/null || {
    echo "error: the GitHub CLI (gh) isn't installed — 'brew install gh', then 'gh auth login'" >&2
    exit 1
}

echo "Publishing $VERSION to ${REPO}…"
git add VERSION Info.plist updates/latest.json
git commit -m "Release $VERSION"
git tag "v$VERSION"
git push origin HEAD --tags
gh release create "v$VERSION" "$DMG" --title "mangoclass $VERSION" --notes "$NOTES"

cat <<EOS

Released. Every copy of mangoclass out there will offer $VERSION the next time it opens.

Note that raw.githubusercontent.com caches for about five minutes, so the very first
check after this may still see $CURRENT.
EOS

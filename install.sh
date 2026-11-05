#!/bin/sh
# Installs or updates Matinee from the latest GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/kirakirag/matinee/main/install.sh | sh
set -eu

REPO=kirakirag/matinee
DEST=/Applications/Matinee.app
URL=https://github.com/$REPO/releases/latest/download

fail() { echo "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail "Matinee needs a Mac with Apple Silicon."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 27 ] || fail "Matinee needs macOS 27 or later."
if pgrep -f "^$DEST/Contents/MacOS/" >/dev/null; then
    fail "Matinee is running: quit it (⌘Q) and run this again."
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading Matinee…"
curl -fL --progress-bar -o "$tmp/Matinee.zip" "$URL/Matinee.zip"
curl -fsSL -o "$tmp/Matinee.zip.sha256" "$URL/Matinee.zip.sha256"
expected=$(cut -d' ' -f1 "$tmp/Matinee.zip.sha256")
actual=$(shasum -a 256 "$tmp/Matinee.zip" | cut -d' ' -f1)
[ "$expected" = "$actual" ] || fail "The download doesn't match its checksum. Nothing was installed."

ditto -x -k "$tmp/Matinee.zip" "$tmp/app"
codesign --verify --deep --strict "$tmp/app/Matinee.app" || fail "The app's signature is broken. Nothing was installed."

rm -rf "$DEST"
ditto "$tmp/app/Matinee.app" "$DEST"
echo "Installed $DEST. Open it from Launchpad or Spotlight."

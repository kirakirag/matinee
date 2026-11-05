#!/bin/bash
# Copies Homebrew's ffmpeg into Matinee/Matinee/Mpv.bundle/bin/ffmpeg for the worker's downloads (yt-dlp merges video
# and audio with it). It links the libraries bundle_mpv.sh already put in Mpv.bundle/lib, so run that first.
# Usage: Scripts/bundle_ffmpeg.sh [signing identity, default ad hoc "-"]   (needs the pinned Homebrew ffmpeg)
set -euo pipefail
cd "$(dirname "$0")/.."

FFMPEG_VERSION=9.0.2
FFMPEG=/opt/homebrew/opt/ffmpeg/bin/ffmpeg
LIB=Matinee/Matinee/Mpv.bundle/lib
OUT=Matinee/Matinee/Mpv.bundle/bin/ffmpeg
IDENTITY=${1:--}

installed=$("$FFMPEG" -version | awk 'NR==1 { print $3 }')
if [ "$installed" != "$FFMPEG_VERSION" ]; then
    echo "Homebrew ffmpeg $installed is installed, but this script is pinned to $FFMPEG_VERSION." >&2
    exit 1
fi
[ -d "$LIB" ] || { echo "$LIB is missing: run Scripts/bundle_mpv.sh first." >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
cp "$(realpath "$FFMPEG")" "$OUT"
chmod u+w "$OUT"

# Its libraries are mpv's too (libavcodec, libavformat, …): point them at the bundle's copies.
missing=""
while read -r dep; do
    name=$(basename "$dep")
    [ -e "$LIB/$name" ] || missing="$missing $name"
    install_name_tool -change "$dep" "@rpath/$name" "$OUT"
done < <(otool -L "$OUT" | awk '/^\t\/opt\/homebrew\// { print $1 }')
if [ -n "$missing" ]; then
    echo "ffmpeg needs libraries that are not in $LIB:$missing" >&2
    exit 1
fi
while read -r rpath; do
    install_name_tool -delete_rpath "$rpath" "$OUT"
done < <(otool -l "$OUT" | awk '$1 == "path" && $2 ~ /^\/opt\/homebrew/ { print $2 }')
install_name_tool -add_rpath "@executable_path/../lib" "$OUT"

# A child of the sandboxed app: it inherits the sandbox and needs nothing else.
codesign --force --sign "$IDENTITY" --entitlements Matinee/Child.entitlements "$OUT"

# Verify (output captured first: `otool | grep -q` can die of SIGPIPE under pipefail and read as no match).
refs=$(otool -L "$OUT" | awk 'NR > 1 { print $1 }')
rpaths=$(otool -l "$OUT" | awk '$1 == "path" { print $2 }')
if [[ "$refs$rpaths" == */opt/homebrew* ]]; then
    echo "ffmpeg still references /opt/homebrew." >&2
    exit 1
fi
for ref in $refs; do
    case "$ref" in
        /usr/lib/* | /System/*) ;;
        @rpath/*) [ -e "$LIB/${ref#@rpath/}" ] || { echo "ffmpeg: $ref is not in the bundle." >&2; exit 1; } ;;
        *) echo "ffmpeg: unexpected reference $ref." >&2; exit 1 ;;
    esac
done
# Not run here: signed to inherit the app's sandbox, it traps outside the app. The version was checked above.
echo "$OUT: ffmpeg $FFMPEG_VERSION, no /opt/homebrew references"

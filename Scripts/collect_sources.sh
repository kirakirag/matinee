#!/bin/bash
# Writes dist/Matinee-sources.tar: the source code of every GPL or LGPL Homebrew library bundled in Mpv.bundle (ffmpeg's
# included),
# plus mpv v0.41.0 with Matinee's patches. Attach it to each GitHub release next to Matinee.zip; the GPL and LGPL
# ask for the source of the binaries we distribute. Run it after the bundle scripts, on the Mac that built the release.
# Usage: Scripts/collect_sources.sh   (downloads source archives; installs and builds nothing)
set -euo pipefail
cd "$(dirname "$0")/.."

MPV_VERSION=0.41.0
LIB=Matinee/Matinee/Mpv.bundle/lib
[ -d "$LIB" ] || { echo "$LIB is missing: run Scripts/build_mpv.sh first." >&2; exit 1; }

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
dir="$out/Matinee-sources"
mkdir -p "$dir/homebrew"

# Each bundled library's Cellar directory; ffmpeg's binary comes from the same keg as its libraries. libmpv is
# ours (build_mpv.sh), handled below.
kegs=$(for lib in "$LIB"/*.dylib; do
    name=$(basename "$lib")
    [ "$name" = libmpv.2.dylib ] && continue
    match=$(ls -d /opt/homebrew/Cellar/*/*/lib/"$name" 2>/dev/null | head -1)
    [ -n "$match" ] || { echo "No Homebrew keg has $name." >&2; exit 1; }
    dirname "$(dirname "$match")"
done | sort -u)

# The formula Homebrew saved in each keg names the exact sources it built from (the formula may have moved on since):
# the main archive, any resources and any patches. Only copyleft libraries need their source shipped.
for keg in $kegs; do
    f=$(basename "$(dirname "$keg")")
    version=$(basename "$keg")
    rb="$keg/.brew/$f.rb"
    grep -A4 '^  license' "$rb" | grep -q GPL || continue   # the license can span lines
    mkdir "$dir/homebrew/$f-$version"
    cp "$rb" "$dir/homebrew/$f-$version/"   # the build recipe
    # "url sha256" or "url rev:<commit>" for every source the recipe names.
    awk '/^ *url "/ { gsub(/"|,/, "", $2); url = $2 }
         /^ *revision: "/ && url { gsub(/"/, "", $2); print url, "rev:" $2; url = "" }
         /^ *sha256 "/ && url { gsub(/"/, "", $2); print url, $2; url = "" }' "$rb" |
    while read -r url check; do
        if [[ "$check" == rev:* ]]; then
            git clone --quiet --no-checkout "$url" "$out/git"
            git -C "$out/git" archive --prefix="$f-$version/" -o "$dir/homebrew/$f-$version/$f-${check#rev:}.tar.gz" "${check#rev:}"
            rm -rf "${out:?}/git"
        else
            file="$dir/homebrew/$f-$version/$(basename "${url%%\?*}")"
            curl -fsSL -o "$file" "$url"
            [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$check" ] || { echo "$f: checksum mismatch for $url" >&2; exit 1; }
        fi
    done
    echo "$f $version"
done

curl -fsSL -o "$dir/mpv-$MPV_VERSION.tar.gz" "https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VERSION.tar.gz"
mkdir "$dir/mpv-patches"
cp Scripts/mpv/*.patch Scripts/build_mpv.sh Scripts/bundle_mpv.sh "$dir/mpv-patches/"
echo "mpv $MPV_VERSION"

mkdir -p dist
tar -C "$out" -cf dist/Matinee-sources.tar Matinee-sources
echo "Wrote dist/Matinee-sources.tar ($(du -h dist/Matinee-sources.tar | cut -f1))"

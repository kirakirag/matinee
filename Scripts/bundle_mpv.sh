#!/bin/bash
# Builds Matinee/Matinee/Mpv.bundle/lib: Homebrew libmpv and its whole dependency closure, copied flat and
# relinked to @rpath, every dylib signed ad hoc. The app links libmpv.2 from here and finds the rest at run time.
# Usage: Scripts/bundle_mpv.sh   (needs the pinned Homebrew mpv; nothing is installed or changed)
# Scripts/build_mpv.sh runs it with MPV_LIB (its own libmpv instead of Homebrew's) and EXTRA_LIBS (more libraries to
# bundle with their dependencies, space-separated).
set -euo pipefail
cd "$(dirname "$0")/.."

MPV_VERSION=0.41.0
MPV_ROOT=/opt/homebrew/opt/mpv
OUT=Matinee/Matinee/Mpv.bundle/lib

# `pkg-config --modversion mpv` reports the client API version (2.x), so ask the player itself.
if [ -z "${MPV_LIB:-}" ]; then
    installed=$("$MPV_ROOT/bin/mpv" --version | awk 'NR==1 { sub(/^v/, "", $2); print $2 }')
    if [ "$installed" != "$MPV_VERSION" ]; then
        echo "Homebrew mpv $installed is installed, but this script is pinned to $MPV_VERSION." >&2
        exit 1
    fi
fi

rm -rf "$OUT"
# Homebrew's libmpv can't draw into the app's view: drop what build_mpv.sh adds, so the app uses OpenGL.
[ -n "${MPV_LIB:-}" ] || rm -rf "$OUT/../macvk-wid" "$OUT/../vulkan"
mkdir -p "$OUT"

# Walk the dependency closure; each library is copied once, named after its install name.
read -r -a extra <<< "${EXTRA_LIBS:-}"
queue=("${MPV_LIB:-$MPV_ROOT/lib/libmpv.2.dylib}" ${extra[@]+"${extra[@]}"})
while [ ${#queue[@]} -gt 0 ]; do
    path=${queue[0]}
    queue=("${queue[@]:1}")
    name=$(basename "$path")
    [ -e "$OUT/$name" ] && continue
    real=$(realpath "$path")
    cp "$real" "$OUT/$name"
    chmod u+w "$OUT/$name"
    while read -r dep; do
        queue+=("$dep")
    done < <(otool -L "$OUT/$name" | awk '/^\t\/opt\/homebrew\// { print $1 }')
    # @rpath dependencies (brotli) sit next to their parent in the same Cellar lib directory.
    while read -r dep; do
        queue+=("$(dirname "$real")/$(basename "$dep")")
    done < <(otool -L "$OUT/$name" | awk '/^\t@rpath\// { print $1 }')
    # Anything else outside the system would be silently missing from the bundle.
    other=$(otool -L "$OUT/$name" | awk '/^\t(@loader_path|@executable_path|\/usr\/local)/ { print $1 }')
    if [ -n "$other" ]; then
        echo "$name has a dependency this script does not follow: $other" >&2
        exit 1
    fi
done

for lib in "$OUT"/*.dylib; do
    name=$(basename "$lib")
    install_name_tool -id "@rpath/$name" "$lib"
    while read -r dep; do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$lib"
    done < <(otool -L "$lib" | awk '/^\t\/opt\/homebrew\// { print $1 }')
    while read -r rpath; do
        install_name_tool -delete_rpath "$rpath" "$lib"
    done < <(otool -l "$lib" | awk '$1 == "path" && $2 ~ /^\/opt\/homebrew/ { print $2 }')
    codesign --force --sign - "$lib" 2>/dev/null
done

# Verify (output captured first: `otool | grep -q` can die of SIGPIPE under pipefail and read as no match).
for lib in "$OUT"/*.dylib; do
    refs=$(otool -L "$lib" | awk 'NR > 1 { print $1 }')
    rpaths=$(otool -l "$lib" | awk '$1 == "path" { print $2 }')
    if [[ "$refs$rpaths" == */opt/homebrew* ]]; then
        echo "$(basename "$lib") still references /opt/homebrew." >&2
        exit 1
    fi
    for ref in $refs; do
        case "$ref" in
            /usr/lib/* | /System/*) ;;
            @rpath/*) [ -e "$OUT/${ref#@rpath/}" ] || { echo "$(basename "$lib"): $ref is not in the bundle." >&2; exit 1; } ;;
            *) echo "$(basename "$lib"): unexpected reference $ref." >&2; exit 1 ;;
        esac
    done
done
echo "$(ls "$OUT" | wc -l | tr -d ' ') libraries, none reference /opt/homebrew"

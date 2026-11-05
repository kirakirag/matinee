#!/bin/bash
# Builds libmpv with Matinee's patches (Scripts/mpv/*.patch; 0002 lets mpv's Metal/MoltenVK output draw into the
# app's own view through --wid) and bundles it with MoltenVK into Matinee/Matinee/Mpv.bundle, replacing what
# bundle_mpv.sh put there. Run Scripts/bundle_ffmpeg.sh again afterwards: it links the bundled libraries.
# Usage: Scripts/build_mpv.sh   (needs Homebrew packages; it lists missing ones and installs nothing)
set -euo pipefail
cd "$(dirname "$0")/.."

MPV_VERSION=0.41.0
MPV_COMMIT=41f6a645068483470267271e1d09966ca3b9f413   # tag v0.41.0
# Outside the checkout: libmpv records its source paths (Swift code imports mpv's C headers), and a fixed neutral
# folder keeps the builder's home folder out of the binary.
WORK=/tmp/matinee-mpv
SRC=$WORK/src
BUILD=$WORK/build
STAGE=$WORK/stage
PREFIX=$STAGE/usr/local
BUNDLE=Matinee/Matinee/Mpv.bundle

deps=(meson ninja pkgconf ffmpeg libass libplacebo little-cms2 vulkan-loader molten-vk zimg)
missing=()
for dep in "${deps[@]}"; do
    brew list --versions "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing Homebrew packages: ${missing[*]}" >&2
    echo "Install them with: brew install ${missing[*]}" >&2
    exit 1
fi

if [ ! -d "$SRC/.git" ]; then
    git clone --quiet --depth 1 --branch "v$MPV_VERSION" https://github.com/mpv-player/mpv.git "$SRC"
fi
actual=$(git -C "$SRC" rev-parse HEAD)
if [ "$actual" != "$MPV_COMMIT" ]; then
    echo "mpv source is at $actual, expected v$MPV_VERSION ($MPV_COMMIT)." >&2
    exit 1
fi
git -C "$SRC" reset --quiet --hard
git -C "$SRC" clean --quiet -fdx
for patch in Scripts/mpv/*.patch; do
    echo "Applying $(basename "$patch")"
    git -C "$SRC" apply "$PWD/$patch"
done

# Only what Matinee uses: libmpv with Cocoa, Vulkan (Metal through MoltenVK) and OpenGL (the fallback renderer).
# mpv's own macOS media controls stay off: the app runs Now Playing itself.
rm -rf "$BUILD" "$STAGE"
# libmpv also records its prefix, so it gets a neutral one and installs into a staging folder.
meson setup "$BUILD" "$SRC" --buildtype=release --prefix=/usr/local \
    -Dcplayer=false -Dlibmpv=true -Dbuild-date=false \
    -Dcocoa=enabled -Dswift-build=enabled -Dvulkan=enabled -Dgl=enabled \
    -Dmacos-media-player=disabled \
    -Dlua=disabled -Djavascript=disabled -Dlibarchive=disabled -Dlibbluray=disabled -Dvapoursynth=disabled \
    -Drubberband=disabled -Duchardet=disabled -Dmanpage-build=disabled -Dhtml-build=disabled
meson compile -C "$BUILD"
meson install -C "$BUILD" --destdir "$STAGE" >/dev/null
install_name_tool -id @rpath/libmpv.2.dylib "$PREFIX/lib/libmpv.2.dylib" 2>/dev/null   # was /usr/local/lib/…

# The loader finds MoltenVK through its manifest, not by linking, so it's added to the bundle by hand.
moltenvk=$(brew --prefix molten-vk)
MPV_LIB="$PREFIX/lib/libmpv.2.dylib" EXTRA_LIBS="$moltenvk/lib/libMoltenVK.dylib" Scripts/bundle_mpv.sh
manifest=$(find "$moltenvk/" -name MoltenVK_icd.json | head -1)
[ -n "$manifest" ] || { echo "No MoltenVK_icd.json under $moltenvk." >&2; exit 1; }
mkdir -p "$BUNDLE/vulkan"
cp "$manifest" "$BUNDLE/vulkan/MoltenVK_icd.json"   # the app writes a copy with the bundled library's path
# Tells the app this libmpv can draw into its view (MPVPlayer.usesMetal).
echo "mpv $MPV_VERSION + $(ls Scripts/mpv | tr '\n' ' ')" > "$BUNDLE/macvk-wid"
echo "Patched libmpv $MPV_VERSION and MoltenVK bundled. Now run Scripts/bundle_ffmpeg.sh again."

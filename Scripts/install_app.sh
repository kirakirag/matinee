#!/bin/bash
# Builds a Release Matinee, re-signs it inside out with "Matinee Local Signing" and installs it in /Applications.
# With --release it writes dist/Matinee.zip and dist/Matinee.zip.sha256 for a GitHub release instead of installing.
# Usage: Scripts/install_app.sh [--release]   (run Scripts/make_signing_identity.sh once first; needs Runtime.bundle and
# Mpv.bundle with bin/ffmpeg, from fetch_runtime.sh, bundle_mpv.sh and bundle_ffmpeg.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Matinee Local Signing"
DEST=/Applications/Matinee.app
CHILD=Matinee/Child.entitlements
APP_ENTITLEMENTS=Scripts/Matinee.release.entitlements
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
release=false
[ "${1:-}" = --release ] && release=true

# 1. Replacing a running app would leave it with a half-swapped bundle.
if ! $release && pgrep -f "^$DEST/Contents/MacOS/" >/dev/null; then
    echo "Matinee is running from $DEST: quit it first." >&2
    exit 1
fi

# 2. The worker the build bundles must be the one in git.
cp Matinee/Worker/matinee_worker.py Matinee/Matinee/Runtime.bundle/
[ -x Matinee/Matinee/Mpv.bundle/bin/ffmpeg ] || { echo "Mpv.bundle/bin/ffmpeg is missing: run Scripts/bundle_ffmpeg.sh." >&2; exit 1; }

# 3. Build.
mkdir -p build
echo "Building Release (log: build/install.log)…"
# Compilers record source paths (#file, __FILE__, debug info): map this checkout to "." and strip the binary's debug
# map, so the app doesn't carry the builder's home folder. The dSYM keeps the symbols.
map="$PWD"
if ! xcodebuild -project Matinee/Matinee.xcodeproj -scheme Matinee -configuration Release \
        -derivedDataPath build/install \
        OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $map=." \
        OTHER_CFLAGS="\$(inherited) -ffile-prefix-map=$map=." \
        DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES \
        build >build/install.log 2>&1; then
    tail -20 build/install.log >&2
    exit 1
fi
product=build/install/Build/Products/Release/Matinee.app

# 4. Stage and re-sign inside out: helpers first, the app last.
identities=$(security find-identity -p codesigning)
if [[ "$identities" != *"\"$IDENTITY\""* ]]; then
    # An ad hoc signature changes with every build, and macOS would then keep each new release out of the sandbox
    # container the previous one made.
    $release && { echo "\"$IDENTITY\" not found: run Scripts/make_signing_identity.sh first." >&2; exit 1; }
    echo "warning: \"$IDENTITY\" not found (run Scripts/make_signing_identity.sh); signing ad hoc." >&2
    IDENTITY=-
fi
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$product" "$stage/Matinee.app"
app="$stage/Matinee.app"
while IFS= read -r -d '' f; do
    [[ "$(file -b "$f")" == *Mach-O* ]] || continue
    case "$(basename "$f")" in
        python3.13 | deno | ffmpeg) codesign --force --sign "$IDENTITY" --entitlements "$CHILD" "$f" ;;   # sandboxed children
        *) codesign --force --sign "$IDENTITY" "$f" ;;
    esac
done < <(find "$app/Contents/Resources" -path '*.bundle/*' -type f -print0)
# Hardened runtime on the app, so DYLD_* variables can't inject code into it. The helpers stay as they are: Deno's
# V8 needs JIT, which the hardened runtime would forbid, and the app sandbox already contains them.
codesign --force --sign "$IDENTITY" --options runtime --entitlements "$APP_ENTITLEMENTS" "$app"

# 5. Verify.
codesign --verify --deep --strict "$app"
entitlements=$(codesign -d --entitlements - "$app" 2>/dev/null)
for forbidden in get-task-allow allow-dyld-environment-variables allow-jit allow-unsigned-executable-memory; do
    if [[ "$entitlements" == *"$forbidden"* ]]; then
        echo "The staged app has $forbidden." >&2
        exit 1
    fi
done
for required in app-sandbox network.client assets.movies.read-write files.user-selected.read-only; do
    if [[ "$entitlements" != *"com.apple.security.$required"* ]]; then
        echo "The staged app lacks com.apple.security.$required." >&2
        exit 1
    fi
done
details=$(codesign -d --verbose=2 "$app" 2>&1)
if [[ "$details" != *"flags="*runtime* ]]; then
    echo "The staged app is not signed with the hardened runtime." >&2
    exit 1
fi

# 6. Package or install.
if $release; then
    rm -f dist/Matinee.zip dist/Matinee.zip.sha256
    mkdir -p dist
    ditto -c -k --keepParent "$app" dist/Matinee.zip
    (cd dist && shasum -a 256 Matinee.zip >Matinee.zip.sha256)
    echo "Wrote dist/Matinee.zip and dist/Matinee.zip.sha256 (signed with $IDENTITY)"
    exit 0
fi
rm -rf "$DEST"
ditto "$app" "$DEST"
echo "Installed $DEST (signed with $IDENTITY)"

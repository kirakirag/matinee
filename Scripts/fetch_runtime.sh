#!/bin/bash
# Builds Matinee/Matinee/Runtime.bundle: relocatable CPython with pinned yt-dlp, Deno, and the worker
# script, every Mach-O file signed. Everything downloaded is checked against Scripts/runtime.lock.
# Usage: Scripts/fetch_runtime.sh [codesign identity]   (default "-": ad hoc)
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/runtime.lock

IDENTITY="${1:--}"
CACHE=Runtime-cache
OUT=Matinee/Matinee/Runtime.bundle
CHILD_ENTITLEMENTS=Matinee/Child.entitlements

fetch() {   # url, file name in cache, sha256
    if [ ! -f "$CACHE/$2" ]; then
        curl -fL --retry 3 -o "$CACHE/$2.part" "$1"
        mv "$CACHE/$2.part" "$CACHE/$2"
    fi
    echo "$3  $CACHE/$2" | shasum -a 256 -c -
}

mkdir -p "$CACHE"
fetch "$PYTHON_URL" python.tar.gz "$PYTHON_SHA256"
fetch "$DENO_URL" deno.zip "$DENO_SHA256"

rm -rf "$OUT"
mkdir -p "$OUT"
tar -xzf "$CACHE/python.tar.gz" -C "$OUT"      # -> python/
unzip -q "$CACHE/deno.zip" -d "$OUT"            # -> deno
PY="$OUT/python/bin/python3"

"$PY" -I -m pip install --quiet --disable-pip-version-check --no-deps --require-hashes --no-compile \
    --only-binary=:all: -r Scripts/runtime-requirements.txt
# Bytecode records its source path: strip this checkout's location so the app doesn't carry the builder's home folder.
"$PY" -I -m compileall -q -f -s "$OUT/" "$OUT/python/lib"
# pip's console scripts start with an absolute shebang into this checkout; the app only runs python3.
{ grep -l "^#!$PWD/" "$OUT"/python/bin/* || true; } | xargs rm -f

LIB="$OUT/python/lib/python3.13"
rm -rf "$LIB"/site-packages/pip "$LIB"/site-packages/pip-* "$LIB/ensurepip" "$LIB/idlelib" "$OUT"/python/bin/pip*
cp Matinee/Worker/matinee_worker.py "$OUT/"

# Libraries first, then the two executables with the child entitlements (sandbox + inherit).
find "$OUT" -type f | while read -r f; do
    if file -b "$f" | grep -q '^Mach-O' && [ "$f" != "$OUT/deno" ] && [ "$f" != "$OUT/python/bin/python3.13" ]; then
        codesign --force --sign "$IDENTITY" "$f"
    fi
done
codesign --force --sign "$IDENTITY" --entitlements "$CHILD_ENTITLEMENTS" "$OUT/python/bin/python3.13"
codesign --force --sign "$IDENTITY" --entitlements "$CHILD_ENTITLEMENTS" "$OUT/deno"

codesign --verify --strict "$OUT/python/bin/python3.13"
codesign --verify --strict "$OUT/deno"
echo "Runtime ready: $OUT"

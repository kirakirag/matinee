#!/bin/sh
# Copies MatineeKit and its tests into this package, adding the Linux Foundation modules each file may need.
set -e
cd "$(dirname "$0")"
REPO=$(cd ../../Matinee && pwd)
rm -rf Sources/MatineeKit Tests
mkdir -p Sources/MatineeKit Tests/MatineeKitTests
prelude='#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif
'
copy() {   # $1 source dir, $2 dest dir
    (cd "$1" && find . -name '*.swift') | while read -r f; do
        mkdir -p "$2/$(dirname "$f")"
        { printf '%s' "$prelude"; cat "$1/$f"; } > "$2/$f"
    done
}
copy "$REPO/MatineeKit" Sources/MatineeKit
copy "$REPO/MatineeKitTests" Tests/MatineeKitTests
cp LinuxCompat.swift Sources/MatineeKit/
ln -s "$REPO/MatineeKitTests/Fixtures" Tests/MatineeKitTests/Fixtures

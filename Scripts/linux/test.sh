#!/bin/sh
# Builds MatineeKit and runs MatineeKitTests in the chroot from setup_chroot.sh. Args go to `swift test`,
# e.g. Scripts/linux/test.sh --filter 'WorkerClientTests|ListingTests'
set -e
R=${CHROOT:-/opt/resolute}
HERE=$(cd "$(dirname "$0")" && pwd)
"$HERE/sync.sh"
CA=; [ -f "$R/etc/ccr-ca.crt" ] && CA="SSL_CERT_FILE=/etc/ccr-ca.crt GIT_SSL_CAINFO=/etc/ccr-ca.crt"
# -sil-verify-none: Ubuntu's assertion-enabled 6.1.3 crashes verifying RangedStream.init (a compiler bug).
chroot "$R" env HOME=/root $CA sh -c 'cd "$0" && swift build --build-tests -Xswiftc -Xfrontend -Xswiftc -sil-verify-none &&
    swift test --skip-build "$@"' "$HERE" "$@"

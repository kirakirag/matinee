#!/bin/sh
# One-time, as root on an Ubuntu cloud container: an Ubuntu 26.04 chroot with its packaged Swift 6.1.3
# (download.swift.org is blocked there; the Ubuntu mirror is not). The repo is bind-mounted at the same path.
set -e
R=${CHROOT:-/opt/resolute}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
command -v debootstrap >/dev/null || apt-get install -y -qq debootstrap
[ -e /usr/share/debootstrap/scripts/resolute ] || ln -s gutsy /usr/share/debootstrap/scripts/resolute
[ -x "$R/usr/bin/apt-get" ] || debootstrap --variant=minbase --components=main,universe resolute "$R" http://archive.ubuntu.com/ubuntu/
echo "deb http://archive.ubuntu.com/ubuntu resolute main universe" > "$R/etc/apt/sources.list"
[ -f /root/.ccr/ca-bundle.crt ] && cp /root/.ccr/ca-bundle.crt "$R/etc/ccr-ca.crt"   # the cloud's HTTPS proxy CA
# -ef: already visible there (e.g. a worktree inside an already-mounted repo), so mounting again would stack mounts.
for d in /proc /dev "$REPO"; do mkdir -p "$R$d"; [ "$d" -ef "$R$d" ] || mount --bind "$d" "$R$d"; done
chroot "$R" env http_proxy="$http_proxy" https_proxy="$https_proxy" DEBIAN_FRONTEND=noninteractive sh -c \
    'apt-get update -qq && apt-get install -y -qq --no-install-recommends swiftlang libsqlite3-dev git g++ ca-certificates >/dev/null'
chroot "$R" swift --version

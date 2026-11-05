#!/bin/bash
# Throwaway: build PlaybackSpike.app, ad-hoc signed with App Sandbox entitlements.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -vE "deprecated|^\s*\||^\s*$|note:" || true
APP=out/PlaybackSpike.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PlaybackSpike "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp ../resolve_worker.py "$APP/Contents/Resources/"
codesign --force -s - --entitlements spike.entitlements "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -c app-sandbox

#!/bin/bash
# Check a published CP Remote disk image: it verifies and its signature
# verifies, it holds the app with the expected name, version and bundle id,
# the app is universal (arm64 and x86_64), its signature verifies and carries
# the hardened runtime, and the Applications shortcut is there. Usage: check-dmg.sh <path.dmg> <version>
set -euo pipefail

dmg="${1:?usage: check-dmg.sh <path.dmg> <version>}"
version="${2:?usage: check-dmg.sh <path.dmg> <version>}"
here="$(cd "$(dirname "$0")" && pwd)"
failures=0
check() { if "$@"; then echo "ok: $*"; else echo "FAILED: $*"; failures=$((failures + 1)); fi; }

check bash -c 'hdiutil verify "$1" >/dev/null' _ "$dmg"
check codesign --verify --strict "$dmg"

mount="$(mktemp -d)"
# Set before the attach, so a failed attach still removes the mount point.
trap 'hdiutil detach "$mount" -quiet 2>/dev/null || true; rmdir "$mount" 2>/dev/null || true' EXIT
hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null

app="$mount/CPRemote.app"
plist="$app/Contents/Info"
check test -d "$app"
check test "$(defaults read "$plist" CFBundleShortVersionString)" = "$version"
check test "$(defaults read "$plist" CFBundleIdentifier)" = "com.jaumeap.cpremote"
check test "$(defaults read "$plist" CFBundleDisplayName)" = "CP Remote"
check test -x "$app/Contents/MacOS/CPRemote"
# Universal: it must run on Apple silicon and on Intel Macs.
check lipo "$app/Contents/MacOS/CPRemote" -verify_arch arm64
check lipo "$app/Contents/MacOS/CPRemote" -verify_arch x86_64
check test -s "$app/Contents/Resources/AppIcon.icns"
check test -n "$(defaults read "$plist" NSLocalNetworkUsageDescription)"
check codesign --verify --strict "$app"
check bash -c 'codesign -d --verbose=2 "$1" 2>&1 | grep -q "flags=.*runtime"' _ "$app"
check test -L "$mount/Applications"
check test -s "$mount/Release Notes.pdf"
check test "$(file -b --mime-type "$mount/Release Notes.pdf")" = "application/pdf"
check bash -c 'swift "$1" "$2" | grep -m1 -E "^[0-9]+\.[0-9]+\.[0-9]+ \(" | grep -q "^$3 ("' _ "$here/pdf-text.swift" "$mount/Release Notes.pdf" "$version"

if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"

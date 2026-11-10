#!/bin/bash
# Check a published CP Remote disk image: it verifies, it holds the app with
# the expected name, version and bundle id, the app's signature verifies, and
# the Applications shortcut is there. Usage: check-dmg.sh <path.dmg> <version>
set -euo pipefail

dmg="${1:?usage: check-dmg.sh <path.dmg> <version>}"
version="${2:?usage: check-dmg.sh <path.dmg> <version>}"
failures=0
check() { if "$@"; then echo "ok: $*"; else echo "FAILED: $*"; failures=$((failures + 1)); fi; }

check hdiutil verify "$dmg" >/dev/null

mount="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null
trap 'hdiutil detach "$mount" -quiet 2>/dev/null || true; rmdir "$mount" 2>/dev/null || true' EXIT

app="$mount/CPRemote.app"
plist="$app/Contents/Info"
check test -d "$app"
check test "$(defaults read "$plist" CFBundleShortVersionString)" = "$version"
check test "$(defaults read "$plist" CFBundleIdentifier)" = "com.jaumeap.cpremote"
check test "$(defaults read "$plist" CFBundleDisplayName)" = "CP Remote"
check test -x "$app/Contents/MacOS/CPRemote"
check codesign --verify --strict "$app"
check test -L "$mount/Applications"

if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"

#!/bin/bash
# Build CP Remote in release mode as a universal binary (arm64 and x86_64),
# wrap it in a .app bundle and pack it in
# a DMG with an Applications shortcut for drag-and-drop installation. Writes
# CPRemote-<version>.dmg and an identical CPRemote.dmg (fixed name, for the
# "latest release" download link).
#
# Usage: macos/scripts/make-dmg.sh <output-dir>
#
# The bundle (with the hardened runtime) and the disk image are ad-hoc signed
# (no Developer ID, not notarized): on another Mac, Gatekeeper warns the first
# time it opens (on macOS 15 and later, System Settings, Privacy & Security,
# Open Anyway). Run on the Mac itself: macOS builds are always done locally.
set -euo pipefail

VERSION="1.0.14"
BUNDLE_VERSION="15"
APP_NAME="CPRemote"

here="$(cd "$(dirname "$0")/.." && pwd)"   # the macos/ folder
out="${1:?usage: make-dmg.sh <output-dir>}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A universal binary: Apple silicon and Intel Macs on macOS 14 or later.
(cd "$here" && swift build -c release --arch arm64 --arch x86_64)
# Where a multi-arch build lands depends on the SwiftPM version: ask it.
binary="$(cd "$here" && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
[ -x "$binary" ] || { echo "no release binary at $binary" >&2; exit 1; }
for arch in arm64 x86_64; do
    lipo "$binary" -verify_arch "$arch" || { echo "the binary lacks $arch" >&2; exit 1; }
done

app="$work/stage/$APP_NAME.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/$APP_NAME"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>CP Remote</string>
    <key>CFBundleIdentifier</key><string>com.jaumeap.cpremote</string>
    <key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Jaume Puig. All rights reserved.</string>
    <key>NSLocalNetworkUsageDescription</key><string>CP Remote connects to Dolby cinema processors on your local network to read their state and send their controls.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF
swift "$here/scripts/make-icon.swift" "$app/Contents/Resources/AppIcon.icns"
# Ad-hoc signature (no certificate) with the hardened runtime, as DCP-o-matic
# signs with its Developer ID. A secure timestamp needs a real identity.
codesign --force --options runtime --sign - "$app"
codesign --verify --strict "$app"

# The release notes of every version, as a PDF next to the app. The build stops
# if the notes do not start with the version being built.
swift "$here/scripts/make-release-notes-pdf.swift" "$here/RELEASE_NOTES.md" "$work/stage/Release Notes.pdf" "$VERSION"

ln -s /Applications "$work/stage/Applications"
dmg="$out/$APP_NAME-$VERSION.dmg"
rm -f "$dmg"
hdiutil create -volname "CP Remote $VERSION" -srcfolder "$work/stage" -ov -format UDZO "$dmg" >/dev/null
# The disk image is signed too (ad hoc), as the app inside it.
codesign --force --sign - "$dmg"
codesign --verify --strict "$dmg"
hdiutil verify "$dmg" >/dev/null
echo "$dmg"

# The same disk image under a fixed name, for the link that always points to
# the newest release (.../releases/latest/download/CPRemote.dmg). Upload both
# files to every GitHub release.
latest="$out/$APP_NAME.dmg"
cp -f "$dmg" "$latest"
echo "$latest"

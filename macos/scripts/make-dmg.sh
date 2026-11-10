#!/bin/bash
# Build CP Remote in release mode, wrap it in a .app bundle and pack it in
# a DMG with an Applications shortcut for drag-and-drop installation.
#
# Usage: macos/scripts/make-dmg.sh <output-dir>
#
# The bundle is ad-hoc signed (no Developer ID, not notarized): on another
# Mac, Gatekeeper asks to open it with Control-click, Open. Run on the Mac
# itself: macOS builds are always done locally.
set -euo pipefail

VERSION="1.0.3"
BUNDLE_VERSION="4"
APP_NAME="CPRemote"

here="$(cd "$(dirname "$0")/.." && pwd)"   # the macos/ folder
out="${1:?usage: make-dmg.sh <output-dir>}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

(cd "$here" && swift build -c release)
binary="$here/.build/release/$APP_NAME"
[ -x "$binary" ] || { echo "no release binary at $binary" >&2; exit 1; }

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
codesign --force --sign - "$app"
codesign --verify --strict "$app"

# The release notes of every version, as a PDF next to the app. The build stops
# if the notes do not start with the version being built.
swift "$here/scripts/make-release-notes-pdf.swift" "$here/RELEASE_NOTES.md" "$work/stage/Release Notes.pdf" "$VERSION"

ln -s /Applications "$work/stage/Applications"
dmg="$out/$APP_NAME-$VERSION.dmg"
rm -f "$dmg"
hdiutil create -volname "CP Remote $VERSION" -srcfolder "$work/stage" -ov -format UDZO "$dmg" >/dev/null
hdiutil verify "$dmg" >/dev/null
echo "$dmg"

#!/bin/bash
# Check that this Mac can build and test CP Remote. Safe to run any time; it
# installs nothing.
#
# It needs the system's own Swift (Xcode or the Command Line Tools, through
# xcrun) at version 6 or newer, with a macOS SDK that carries SwiftUI and
# Network. If both are there it prints "local" and exits 0. If not, or on any
# system other than macOS, it prints "unavailable" and exits 2: the app is
# SwiftUI and AppKit and links a macOS-only library, so it builds only on a Mac.
#
# Usage: macos/scripts/ensure-swift.sh
set -euo pipefail

log() { echo "ensure-swift: $*" >&2; }

unavailable() {
    log "$1"
    echo unavailable
    exit 2
}

# True if the command in "$@" is a swift whose major version is 6 or more.
swift_ok() {
    local major
    major="$("$@" --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p' | head -1)"
    [ -n "$major" ] && [ "$major" -ge 6 ]
}

[ "$(uname -s)" = Darwin ] || unavailable "CP Remote builds only on a Mac, not on $(uname -s)"

swift_ok xcrun swift || unavailable "no system Swift 6: install Xcode or the Command Line Tools"

sdk="$(xcrun --show-sdk-path 2>/dev/null || true)"
if [ -z "$sdk" ] \
    || [ ! -d "$sdk/System/Library/Frameworks/SwiftUI.framework" ] \
    || [ ! -d "$sdk/System/Library/Frameworks/Network.framework" ]; then
    unavailable "no macOS SDK with SwiftUI and Network: install Xcode or the Command Line Tools"
fi

log "local: $(xcrun swift --version 2>&1 | grep -m1 'Swift version'), SDK $sdk"
echo local

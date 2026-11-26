#!/bin/bash
# Decide where CP Remote is built and tested, and make sure a Swift 6
# toolchain is there when the answer is "here". Safe to run any time.
#
# The order:
#   1. On a Mac: the system's own Swift (Xcode or the Command Line Tools,
#      through xcrun) at version 6 or newer, with a macOS SDK that carries
#      SwiftUI and Network. If both are there, build and test locally: prints
#      "local" and exits 0. If not, nothing is installed: prints "ci" and
#      exits 2. Nothing runs in CI: the Mac that has no SDK must get one.
#   2. On Linux: a system Swift on PATH at version 6 or newer. If there is
#      none, Swift $SWIFT_VERSION is downloaded from download.swift.org and
#      unpacked in the session scratchpad, $SWIFT_SCRATCH_DIR/swift-<version>,
#      never in the home folder. Prints "local" and exits 0. The app is
#      SwiftUI and AppKit, so it builds only on a Mac, locally or in CI.
#
# In a Claude Code session ($CLAUDE_ENV_FILE set), a scratchpad toolchain's
# bin folder is added to PATH for the rest of the session. Nothing is written
# outside $SWIFT_SCRATCH_DIR and that file.
#
# Usage: macos/scripts/ensure-swift.sh
# Variables: SWIFT_SCRATCH_DIR (the session scratchpad; required only when
#            Swift has to be downloaded), SWIFT_VERSION (default 6.3.3, the
#            version of the macOS CI).
set -euo pipefail

version="${SWIFT_VERSION:-6.3.3}"

log() { echo "ensure-swift: $*" >&2; }

# True if the command in "$@" is a swift whose major version is 6 or more.
swift_ok() {
    local major
    major="$("$@" --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p' | head -1)"
    [ -n "$major" ] && [ "$major" -ge 6 ]
}

on_mac() {
    local sdk
    if ! swift_ok xcrun swift; then
        log "no system Swift 6 (Xcode or the Command Line Tools): use the macOS CI workflow"
        echo ci
        exit 2
    fi
    sdk="$(xcrun --show-sdk-path 2>/dev/null || true)"
    if [ -z "$sdk" ] \
        || [ ! -d "$sdk/System/Library/Frameworks/SwiftUI.framework" ] \
        || [ ! -d "$sdk/System/Library/Frameworks/Network.framework" ]; then
        log "no macOS SDK with SwiftUI and Network: use the macOS CI workflow"
        echo ci
        exit 2
    fi
    log "local: $(xcrun swift --version 2>&1 | grep -m1 'Swift version'), SDK $sdk"
    echo local
}

install_in_scratch() {
    local scratch="${SWIFT_SCRATCH_DIR:?set SWIFT_SCRATCH_DIR to the session scratchpad}"
    local distro suffix arch os_id os_version
    # shellcheck disable=SC1091
    os_id="$(. /etc/os-release && echo "${ID:-}")"
    # shellcheck disable=SC1091
    os_version="$(. /etc/os-release && echo "${VERSION_ID:-}")"
    case "$os_id-$os_version" in
        ubuntu-24.04) distro="ubuntu2404"; suffix="ubuntu24.04" ;;
        ubuntu-22.04) distro="ubuntu2204"; suffix="ubuntu22.04" ;;
        *) log "no prebuilt Swift $version for $os_id $os_version: install Swift from swift.org by hand"; exit 1 ;;
    esac
    case "$(uname -m)" in
        x86_64) arch="" ;;
        aarch64 | arm64) distro="$distro-aarch64"; arch="-aarch64" ;;
        *) log "unsupported CPU $(uname -m)"; exit 1 ;;
    esac
    local target="$scratch/swift-$version"
    if ! swift_ok "$target/usr/bin/swift"; then
        local name="swift-$version-RELEASE-$suffix$arch"
        local url="https://download.swift.org/swift-$version-release/$distro/swift-$version-RELEASE/$name.tar.gz"
        local tmp
        mkdir -p "$scratch"
        tmp="$(mktemp -d "$scratch/swift-download.XXXXXX")"
        # shellcheck disable=SC2064
        trap "rm -rf '$tmp'" EXIT
        log "downloading Swift $version (about 1 GB) into $scratch"
        curl -fL --retry 3 --retry-delay 5 -sS -o "$tmp/swift.tar.gz" "$url"
        mkdir -p "$tmp/unpacked"
        tar -xzf "$tmp/swift.tar.gz" --strip-components=1 -C "$tmp/unpacked"
        rm -rf "$target"
        mv "$tmp/unpacked" "$target"
        if ! swift_ok "$target/usr/bin/swift"; then
            log "Swift $version unpacked but does not run. On Ubuntu it needs: apt-get install -y libcurl4-openssl-dev libxml2-dev libncurses-dev libedit-dev libsqlite3-dev libz3-dev"
            exit 1
        fi
    fi
    if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
        local line="export PATH=\"$target/usr/bin:\$PATH\""
        grep -qxF "$line" "$CLAUDE_ENV_FILE" 2>/dev/null || echo "$line" >> "$CLAUDE_ENV_FILE"
    fi
    log "local: Swift $version from $target (add $target/usr/bin to PATH)"
    echo local
}

case "$(uname -s)" in
    Darwin) on_mac ;;
    Linux)
        if swift_ok swift; then
            log "local: system $(swift --version 2>&1 | grep -m1 'Swift version')"
            echo local
        else
            install_in_scratch
        fi
        ;;
    *) log "unsupported system $(uname -s): use the macOS CI workflow"; echo ci; exit 2 ;;
esac

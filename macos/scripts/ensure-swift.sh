#!/bin/bash
# Make sure a Swift 6 toolchain is available, and install one for the user if
# it is not. Safe to run any time: when Swift is already there it only checks
# the version and returns.
#
# Where Swift comes from, in this order:
#   1. The user-level toolchain this script installed:
#      $SWIFT_TOOLCHAIN_HOME/current (default ~/.swift-toolchain/current).
#   2. Any other `swift` on PATH that is version 6 or newer (Xcode on a Mac).
#   3. A download from download.swift.org (Linux only), unpacked in
#      $SWIFT_TOOLCHAIN_HOME/swift-$SWIFT_VERSION, no root needed.
#
# After an install it also writes small `swift` and `swiftc` wrappers into
# $SWIFT_WRAPPER_DIR (default ~/.local/bin). A wrapper runs the toolchain, and
# runs this script first if the toolchain has gone missing, so any later
# `swift build` or `swift test` finds Swift without anybody asking for it.
#
# In a Claude Code cloud session ($CLAUDE_ENV_FILE set) the toolchain's bin
# folder is also added to PATH for the rest of the session.
#
# Only the Swift on Linux builds the logic of CPx50Comms that does not touch
# Darwin, Network or SwiftUI (LineBuffer, CommandQueue, WireProtocol,
# ProtocolTiming, ProcessorModel, ProcessorState). The app and the transports
# build on macOS, in CI.
#
# Usage: macos/scripts/ensure-swift.sh [--no-wrappers]
# Variables: SWIFT_VERSION (default 6.3.3, the version of the macOS CI),
#            SWIFT_TOOLCHAIN_HOME, SWIFT_WRAPPER_DIR.
set -euo pipefail

version="${SWIFT_VERSION:-6.3.3}"
home_dir="${SWIFT_TOOLCHAIN_HOME:-$HOME/.swift-toolchain}"
wrapper_dir="${SWIFT_WRAPPER_DIR:-$HOME/.local/bin}"
marker="swift-toolchain-wrapper"
make_wrappers=1
[ "${1:-}" = "--no-wrappers" ] && make_wrappers=0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "ensure-swift: $*" >&2; }

# True if $1 is a swift whose major version is 6 or more.
swift_ok() {
    local major
    major="$("$1" --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p' | head -1)"
    [ -n "$major" ] && [ "$major" -ge 6 ]
}

# A swift on PATH that is not one of our wrappers.
other_swift() {
    local candidate
    while IFS= read -r candidate; do
        grep -q "$marker" "$candidate" 2>/dev/null && continue
        if swift_ok "$candidate"; then echo "$candidate"; return 0; fi
    done < <(type -ap swift 2>/dev/null || true)
    return 1
}

install_toolchain() {
    case "$(uname -s)" in
        Linux) ;;
        *) log "no Swift 6 found. On a Mac install Xcode (or the toolchain from swift.org)."; exit 1 ;;
    esac
    local arch distro suffix os_id os_version
    # shellcheck disable=SC1091
    os_id="$(. /etc/os-release && echo "${ID:-}")"
    # shellcheck disable=SC1091
    os_version="$(. /etc/os-release && echo "${VERSION_ID:-}")"
    case "$os_id-$os_version" in
        ubuntu-24.04) distro="ubuntu2404"; suffix="ubuntu24.04" ;;
        ubuntu-22.04) distro="ubuntu2204"; suffix="ubuntu22.04" ;;
        *) log "no prebuilt Swift $version for $os_id $os_version here: install Swift from swift.org by hand."; exit 1 ;;
    esac
    case "$(uname -m)" in
        x86_64) arch="" ;;
        aarch64 | arm64) distro="$distro-aarch64"; arch="-aarch64" ;;
        *) log "unsupported CPU $(uname -m)"; exit 1 ;;
    esac
    local name="swift-$version-RELEASE-$suffix$arch"
    local url="https://download.swift.org/swift-$version-release/$distro/swift-$version-RELEASE/$name.tar.gz"
    local target="$home_dir/swift-$version"
    mkdir -p "$home_dir"
    local tmp
    tmp="$(mktemp -d "$home_dir/download.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    log "downloading Swift $version (about 1 GB) from download.swift.org"
    curl -fL --retry 3 --retry-delay 5 -sS -o "$tmp/swift.tar.gz" "$url"
    mkdir -p "$tmp/unpacked"
    tar -xzf "$tmp/swift.tar.gz" --strip-components=1 -C "$tmp/unpacked"
    rm -rf "$target"
    mv "$tmp/unpacked" "$target"
    ln -sfn "$target" "$home_dir/current"
    if ! swift_ok "$home_dir/current/usr/bin/swift"; then
        log "Swift $version unpacked but does not run. On Ubuntu it needs: apt-get install -y libcurl4-openssl-dev libxml2-dev libncurses-dev libedit-dev libsqlite3-dev libz3-dev"
        exit 1
    fi
    log "installed Swift $version in $target"
}

write_wrapper() {
    local tool="$1" file="$wrapper_dir/$1"
    # Never overwrite a file that is not one of our wrappers.
    if [ -e "$file" ] && ! grep -q "$marker" "$file" 2>/dev/null; then
        log "$file exists and is not ours: left alone"
        return
    fi
    mkdir -p "$wrapper_dir"
    cat > "$file" <<EOF
#!/bin/bash
# $marker: runs the user-level Swift toolchain, installing it first if it is gone.
# Written by macos/scripts/ensure-swift.sh.
tc="\${SWIFT_TOOLCHAIN_HOME:-$home_dir}/current/usr/bin"
if [ ! -x "\$tc/$tool" ]; then
    "$here/ensure-swift.sh" --no-wrappers >&2 || exit 1
fi
exec "\$tc/$tool" "\$@"
EOF
    chmod +x "$file"
}

if swift_ok "$home_dir/current/usr/bin/swift"; then
    : # the user-level toolchain is there
elif other_swift >/dev/null; then
    log "using $(other_swift)"
    exit 0
else
    mkdir -p "$home_dir"
    # The wrappers first, so a `swift` typed while the download runs finds one.
    if [ "$make_wrappers" = 1 ]; then
        write_wrapper swift
        write_wrapper swiftc
    fi
    # One install at a time: a second caller (a wrapper, or the hook again)
    # waits here, then finds the toolchain ready.
    exec 9> "$home_dir/.install.lock"
    flock 9
    swift_ok "$home_dir/current/usr/bin/swift" || install_toolchain
fi

if [ "$make_wrappers" = 1 ]; then
    write_wrapper swift
    write_wrapper swiftc
fi

# In a Claude Code cloud session the rest of the session needs the PATH too.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    line="export PATH=\"$home_dir/current/usr/bin:\$PATH\""
    grep -qxF "$line" "$CLAUDE_ENV_FILE" 2>/dev/null || echo "$line" >> "$CLAUDE_ENV_FILE"
fi
log "Swift ready: $("$home_dir/current/usr/bin/swift" --version 2>&1 | head -1)"

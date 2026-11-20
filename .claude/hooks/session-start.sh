#!/bin/bash
# Claude Code cloud sessions: make sure Swift is installed before the session
# starts. macos/scripts/ensure-swift.sh does nothing when Swift 6 is already
# there, so this is cheap after the first run, and it also adds the toolchain
# to PATH for the session. If the toolchain is gone later, the `swift` wrapper
# it leaves in ~/.local/bin installs it again on first use.
#
# Async: the session starts at once and this runs in the background. A `swift`
# command typed before the install ends goes through that wrapper, which waits
# for the install by running it itself, so it never finds Swift missing.
set -euo pipefail

echo '{"async": true, "asyncTimeout": 300000}'

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}"
macos/scripts/ensure-swift.sh

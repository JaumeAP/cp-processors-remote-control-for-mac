#!/bin/bash
# Claude Code cloud sessions: make sure Swift is installed before the session
# starts. macos/scripts/ensure-swift.sh does nothing when Swift 6 is already
# there, so this is cheap after the first run, and it also adds the toolchain
# to PATH for the session. If the toolchain is gone later, the `swift` wrapper
# it leaves in ~/.local/bin installs it again on first use.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}"
macos/scripts/ensure-swift.sh

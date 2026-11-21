# CP Remote

A native macOS app, written in Swift, that shows the front panel of the Dolby
cinema processor you choose: its fader, mute and front-panel buttons.

Supported processors: CP650, CP750, and CP850 / CP950 (the CP950A shares the
CP950's front).

## Status

1. The app is currently interface-only: it has no processor communication.
   It connects to nothing, the controls stay disabled, and Setup's Test button
   only says so.
2. The CP850 has no front-panel figure in the manuals used here; its front
   is the CP950's.

## Requirements

1. macOS 14 or later.
2. Swift 6 (the Command Line Tools are enough; Xcode is not required).

## Build and run

```bash
swift build
swift run CPRemote
```

Build the release app and a disk image with `scripts/make-dmg.sh <output-dir>`,
and check a finished image with `scripts/check-dmg.sh <path.dmg> <version>`.
The image also holds `Release Notes.pdf`, the changes of every version, made
from `RELEASE_NOTES.md`: add the new version's entry at the top of that file
before building (the build stops if the newest entry is not the version being
built).
The app is ad-hoc signed and not notarized. How to open it the first time is
in `INSTALL.md`; the release workflow adds that text to every GitHub Release.

## Connection log

The app writes its events to `~/Library/Logs/CP Remote/connection.log`: its
start, connect requests, and its focus and window events. It rotates at 1 MB.
**Setup, Show Connection Log** reveals the file.

## Tests

From `macos/`:

```bash
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

The tests need no processor.

## Layout

1. `Sources/CPRemote/` — the app: the window, the panels, the Setup sheet,
   and the model they show. See `ARCHITECTURE.md`.
2. `Tests/` — the app tests.
   `RELEASE_NOTES.md` — the changes of every version.
3. `scripts/make-dmg.sh` — builds the release app and its disk image.

## Licence

All rights reserved. See `LICENSE`.

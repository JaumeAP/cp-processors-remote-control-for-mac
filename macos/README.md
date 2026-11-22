# CP Remote

A native macOS app, written in Swift, that shows the front panel of the Dolby
cinema processor you choose: its fader, mute and front-panel buttons.

Supported processors: CP650, CP750, and CP850 / CP950 (the CP950A shares the
CP950's front).

## Status

1. The app talks to the processor over TCP/IP through the released cpseries
   library (`../cpseries-release`): it reads the fader, mute, selected
   button or input, macro and the CP650's programmed formats every two
   seconds, and sends the controls. Serial lines are not supported.
2. The CP850 / CP950 macro list is not read: it is a multi-line reply, which
   the library does not return, so the macro keys step only by number.
3. The CP850 has no front-panel figure in the manuals used here; its front
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

The tests need no processor. `SimulatorLinkTests` also run the model over the
real library when `CPSIM_PORT_CP650`, `CPSIM_PORT_CP750` and
`CPSIM_PORT_CP950` name the ports of running CPSeries simulators
(`processor_sim`, built from `CPSeries/cpp/processor_sim.cpp` outside the
repository); without them they are skipped.

## Layout

1. `Sources/CPRemote/` — the app: the window, the panels, the Setup sheet,
   and the model they show. See `ARCHITECTURE.md`.
2. `Tests/` — the app tests.
   `RELEASE_NOTES.md` — the changes of every version.
3. `scripts/make-dmg.sh` — builds the release app and its disk image.

## Licence

All rights reserved. See `LICENSE`.

# CP Remote

A native macOS app, written in Swift, that controls Dolby cinema processors
over TCP/IP. It shows the front panel of the processor you choose and drives
its fader, mute and front-panel buttons.

Supported processors: CP650, CP750, and CP850 / CP950 (the CP950A shares the
CP950's front and commands).

## Status

1. Tested against the simulator in `simulator/` (every control, every model).
2. Version 1.0 was reported working on a real CP650: it connects over Ethernet
   and the fader, mute and format buttons work. One report is open: after
   losing the link the app can stay inactive until the unit itself is touched.
   See "Connection log" below. Other models are not tested on real hardware.
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
The app is ad-hoc signed and not notarized: the first time, open it with
Control-click, Open.

## Connection log

The app writes what it and its link to the processor do to
`~/Library/Logs/CP Remote/connection.log`: the lines sent and received, status
changes with their reason, timeouts, reconnects, and the app's focus and window
events. It rotates at 1 MB. **Setup, Show Connection Log** reveals the file.
If the link to a processor misbehaves, send that file.

## Tests

The tests that need a processor use the simulator. Build it, then point
`CPSIM_BIN` at the binary:

From the repository root:

```bash
cmake -S simulator -B simulator/build && cmake --build simulator/build
cd macos
CPSIM_BIN=$PWD/../simulator/build/processor_sim \
  swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

Without `CPSIM_BIN` those tests are skipped. The simulator tests start and stop
the simulator themselves.

## Layout

1. `Sources/CPRemote/` — the app: the window, the panels, the Setup sheet,
   and the model that connects them to the processor.
2. `Sources/CPx50Comms/` — the control library: the client, the TCP and serial
   transports, the wire protocol, and the command queue. See `ARCHITECTURE.md`.
3. `Tests/` — the library and app tests.
   `RELEASE_NOTES.md` — the changes of every version.
4. `simulator/` — a C++17 simulator of the processors' control channel.
5. `scripts/make-dmg.sh` — builds the release app and its disk image.

## Using the library

```swift
import CPx50Comms

let cp = DolbyCP(host: "192.168.1.10", model: .cp650)
guard await cp.connect() else { return }
try await cp.set("fader_level", 70)                 // queued; returns at once
let mute = try await cp.get("mute")                 // "0", or nil on no reply
await cp.disconnect()
```

The library has no user interface. It uses Foundation, Network.framework for
TCP, and the POSIX terminal API for serial links.

## Licence

All rights reserved. See `LICENSE`.

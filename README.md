# CP Remote

A macOS app and its control library for Dolby cinema processors: CP650, CP750,
CP850, CP950 and CP950A, over TCP/IP.

In recording and post-production studios the processor usually sits in the
machine room, away from the mix room. CP Remote lets an engineer in the mix
room control it over the local network: the fader, mute, front-panel buttons
and macro selection, with the unit's front panel on screen.

1. [`macos/`](macos/README.md): the app (`CPRemote`) and the library (`CPx50Comms`).
2. [`simulator/`](simulator/README.md): a C++17 simulator of the processors'
   control channel, used by the tests.

See [`macos/ARCHITECTURE.md`](macos/ARCHITECTURE.md) for how the parts fit.

Licence: all rights reserved. See [`LICENSE`](LICENSE).

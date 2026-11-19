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

## Acknowledgements

Thanks to David Sans of Iyuno (Barcelona), who beta-tested CP Remote on a real
CP650 and reported the connection problem that version 1.0.11 fixes.

Thanks to Pau Burillo of TransPerfect (Barcelona) for testing the CP750.

The CP850 and CP950 have not yet been tested on real hardware; they have only
been checked against the simulator. Feedback from anyone who runs CP Remote
on one of them is welcome.

Licence: free use to control the processors listed above; all copyright in the
code is reserved. See [`LICENSE`](LICENSE).

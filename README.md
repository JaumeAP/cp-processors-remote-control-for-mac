# CP Remote

A macOS app and its control library for Dolby cinema processors: CP650, CP750,
CP850, CP950 and CP950A, over TCP/IP.

In recording and post-production studios the processor usually sits in the
machine room, away from the mix room. CP Remote lets an engineer in the mix
room control it over the local network: the fader, mute, front-panel buttons
and macro selection, with the unit's front panel on screen.

[`macos/`](macos/README.md) holds the app (`CPRemote`) and the library
(`CPx50Comms`). See [`macos/ARCHITECTURE.md`](macos/ARCHITECTURE.md) for how the parts fit.

CP Remote was created by Jaume Puig (GitHub: [JaumeAP](https://github.com/JaumeAP),
Instagram: [@jamesapuig](https://www.instagram.com/jamesapuig/)).

It was written from Jaume Puig's 30 years of experience working with Dolby. It
uses only public documents and manuals, and the processors themselves.

## Acknowledgements

Thanks to David Sans of Iyuno (Barcelona), who beta-tested CP Remote on a real
CP650 and reported the connection problem that version 1.0.11 fixes.

Thanks to Pau Burillo of TransPerfect (Barcelona) for testing the CP750.

The CP850 and CP950 have not yet been tested on real hardware. Feedback from
anyone who runs CP Remote on one of them is welcome.

Licence: free use to control the processors listed above; all copyright in the
code is reserved. See [`LICENSE`](LICENSE).

This project is not affiliated with, endorsed by, or sponsored by Dolby
Laboratories. Dolby is a trademark of Dolby Laboratories.

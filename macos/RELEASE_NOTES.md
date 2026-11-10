# CP Remote release notes

## 1.0.6 (2026-11-10)
- CP650: a query is now sent as `KEY=?`, the form Dolby's CP650 manual gives, instead of `KEY?`.
- CP650: the format buttons are numbered 0 to 7 on the wire, as in the manual: button 1 sends `format_button=0` and button 8 sends `format_button=7`. Before, every format button selected the next one.
- Not yet tested on a real CP650; both changes follow the manual as read from public copies.
- Everything in 1.0.5 is included.

## 1.0.5 (2026-11-10)
- The CP750 front panel: the input-select names no longer run into each other, "NonSync" and "Mic" line up with the two-line names, and "Input Select" moved to the foot of the panel.
- Everything in 1.0.4 is included.

## 1.0.4 (2026-11-10)
- A change whose write to the unit timed out is no longer sent a second time: the line could already be on the wire, and a second copy could repeat it or follow a fragment on a serial line.
- The app has an icon, and macOS can now say why the app asks to reach the local network.
- After you choose Disconnect, the background poll no longer reopens the link.
- CPx50Comms is a library product of the package, so other packages can use it.
- Everything in 1.0.3 is included.

## 1.0.3 (2026-11-10)
- The disk image now holds Release Notes.pdf next to the app, with the changes of every version, newest first.
- Everything in 1.0.2 is included.

## 1.0.2 (2026-11-10)
- The CP650 front panel now looks like the unit: light grey face with dark lettering, red header band with white lettering and the Dolby mark, light buttons with dark labels, and black rack ears with white slots. The selected format button stays white and lit.
- Everything in 1.0.1 is included.

## 1.0.1 (2026-11-10)
- Fix: after applying a change (a mute, a format, the fader), a reply from the unit slower than half a second was taken for a lost connection, and the controls were disabled for about five seconds. A change now has three seconds to be answered.
- New: a connection log at ~/Library/Logs/CP Remote/connection.log, with the lines sent and received, status changes with their reason, timeouts, reconnects, and the app's focus and window events. Setup, Show Connection Log reveals the file.
- The CP650 header band is red, as on the unit.
- More tests: CP850 and CP950A, persistence of the settings, reconnection after a cut link, panel rendering, a serial line, the event log.

## 1.0.0 (2026-11-10)
- First release.
- Front panels for the CP650, the CP750 and the CP850 / CP950, drawn after the manuals' figures.
- The fader knob (endless, three turns from 0.0 to 10.0), the mute button and the front-panel buttons work on each model, with each model's own parameter names.
- Setup: processor model, IP address, Test, Save and Connect, Reconnect and Disconnect.
- VoiceOver labels on every control.
- Tested against the simulator; not tested on a real unit.

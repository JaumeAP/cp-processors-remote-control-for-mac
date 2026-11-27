# Release notes

## 1.1.1 (2026-11-26)
- The app bundle now carries the cpx50comms library, so it starts outside the build tree.
- The Macro menu is gone: it only ever said "No macros on this processor", because the macro list is not read. The CP850's macro keys and the CP950's macro name are unchanged.
- CP Remote now runs from macOS 12.0 (Monterey) onward. Version 1.1.0 needed a newer macOS.
- The processor link uses the cpx50comms library of CPSeries v3.0.0, the release the app is built against.

## 1.1.0 (2026-11-22)
- CP Remote now talks to the processor through the cpseries control library (CPSeries 1.1.0), which replaces its own connection code. The fader, mute, the CP650's format buttons and programmed formats, the CP750's inputs and the CP850 / CP950 macro number and name are read and sent as before. It has been checked against a processor simulator, not yet on a real processor.
- Not in this version, compared with 1.0.18: serial lines (USB adapters), the CP850 / CP950 macro list with its names, the window that helps allow CP Remote on the local network, and the lines exchanged with the processor in the connection log. Keep 1.0.18 for any of these.

## 1.0.18 (2026-11-19)
- The window that helps allow CP Remote on the local network now says what applies to the macOS version: from macOS 27.2 it points to the + button of the Local Network list; before that it says to quit and reopen CP Remote from Applications so macOS lists it.
- The "Move to Applications" message no longer says that macOS ties the permission to where the app is; it says a copy run from the disk image disappears when the image is ejected, and macOS may ask again for permissions.
- Every GitHub Release now lists how to open the app the first time and the permissions it needs, per macOS version. On macOS 15 and later Control-click, Open no longer works: use System Settings, Privacy & Security, Open Anyway.
- Everything in 1.0.17 is included.

## 1.0.17 (2026-11-19)
- A serial connection that cannot be opened now says why in the connection log (for example `open /dev/cu.usbserial failed: Permission denied (errno 13)`, the port busy or missing, or a baud rate not supported). Before, it said only "connect failed".
- Everything in 1.0.16 is included.

## 1.0.16 (2026-11-19)
- When macOS blocks the local network, the connection now waits for the user's answer instead of giving up at once. macOS may deny the first attempt while its own permission alert is still on screen, and connects by itself once access is allowed. Every connection of 1.0.14 on a real Mac failed this way, within 10 ms.
- When the local network stays blocked, CP Remote opens System Settings on Privacy & Security, Local Network, and shows a small window with the steps to allow it. The window closes by itself when the app connects.
- When CP Remote runs from the disk image or from the folder it was downloaded to, it asks to be moved to Applications: macOS ties the Local Network permission to where the app is.
- Everything in 1.0.15 is included.

## 1.0.15 (2026-11-19)
- The connection log now says why a connection could not be opened (for example `waiting: … Local network prohibited`, a refused connection, or no answer in time). Before, it said only "connect failed".
- If every connection fails at once after an update, check that CP Remote is allowed in System Settings, Privacy & Security, Local Network: macOS can ask again for each new version.
- Everything in 1.0.14 is included.

## 1.0.14 (2026-11-19)
- CP650: every line is now sent ending in CR LF, as the CP650 manual gives, over the network and over a serial line. Before, a line ended in LF alone, and a real CP650 answered `error` to every query and change: the panel came alive only after a key or the fader was moved on the unit, and the app kept reopening the link.
- The other models are unchanged.
- Everything in 1.0.13 is included.

## 1.0.13 (2026-11-19)
- CP650: after the link opens, the app listens for one second before it sends anything, and reads any line the unit sends on its own. Nothing is sent during that second.
- The CP650 is unchanged otherwise.
- Everything in 1.0.12 is included.

## 1.0.12 (2026-11-19)
- The app is universal again: it runs on Apple silicon and on Intel Macs. The 1.0.11 disk image held an Apple silicon build only.
- CP850: a front panel drawn from photos of the unit, with its screen, navigation keys and macro keys 1 to 8. Key n selects macro n (`sys.macro_preset n`), as in the CP850 manual.
- CP750: the selected format and input keys are shown lit.
- Booth safety: the controls are enabled only once the fader, the selected format or input and the mute have been read from the unit. A newly chosen unit no longer shows the mute state of the previous one, and the fader sends nothing before its first read.
- CP850, CP950 and CP950A: two unanswered macro reads pause the macro poll for five polls instead of stopping it for the rest of the session. A macro number and its name always change together, and the list of macros tolerates a late line.
- CP650: the two-second wait between links counts from every close, including the one after Test. Test uses the main link. A change ignores unrelated lines from the unit, the hung-link watchdog tries both query forms, and the query form switches only after the preferred one has gone unanswered twice in a row.
- Reconnecting while a link is closing no longer leaves a second link or an orphaned watchdog behind.
- Serial: the port is closed when the link ends (50 links used to leave 49 open), the default speed is 9600 baud, and an invalid speed fails the connection instead of opening the port.
- Out-of-range times and retry counts are clamped to a sensible value instead of stopping the app.
- The connection log is saved when the app quits.
- Everything in 1.0.11 is included.

## 1.0.11 (2026-11-18)
- CP650: a query is sent as `KEY?` again, the form a real unit answered with version 1.0. When it draws no reply, the query is repeated as `KEY=?` (the form of the manual, used since 1.0.6), and whichever form the unit answers is used from then on. With 1.0.6 a CP650 appeared not to answer `KEY=?`: the panel stayed inactive until a key was pressed on the unit, then allowed one change.
- One exchange left unanswered no longer disables the controls. They are disabled when the link is down, or when a fader read gets no reply through all its retries, and enabled again once the panel has been read.
- The connection log records which query form the unit answers.
- Everything in 1.0.10 is included.

## 1.0.10 (2026-11-10)
- CP850, CP950 and CP950A: the macros of the processor are listed on the screen, the selected one in white; click one to select it. A new Macro menu does the same with Option-Command-1 to 9, and Next Macro / Previous Macro (Option-Command-Right / Left Arrow). The list and the selected macro are read from the unit.
- The level can be shown in decibels instead of the fader number, on every model: 7.0 is 0 dB, from -90 dB at 0.0 to +10 dB at 10. Click the level display, or choose Level, Show Level in dB (Command-D). The choice is remembered.
- Everything in 1.0.9 is included.

## 1.0.9 (2026-11-10)
- CP850, CP950 and CP950A: the screen now shows the name of the selected macro, read from the processor (`sys.macro_name`), under the fader level. If the unit does not answer it, the screen stays as before.
- Everything in 1.0.8 is included.

## 1.0.8 (2026-11-10)
- New Level menu: Level Up (Command-Up Arrow) and Level Down (Command-Down Arrow) move the fader by 0.1, and Reference 7.0 (Command-0) puts it on the Dolby reference level. They work on every model and are available to VoiceOver from the menu bar.
- Everything in 1.0.7 is included.

## 1.0.7 (2026-11-10)
- CP650: after a link is closed, the app waits two seconds before opening the next one (on Reconnect, on Save and Connect, and when it reopens a hung link), so the unit can drop the old session first. The CP650 takes a single connection; the Q-SYS plugin does the same. Not yet tested on a real CP650.
- Everything in 1.0.6 is included.

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

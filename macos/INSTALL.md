## Install and permissions

Open the disk image, drag CP Remote to Applications and open it from there. The app is ad-hoc signed and not notarized by Apple, so macOS asks for a permission or two. What happens depends on the macOS version.

**First open (Gatekeeper)**
- macOS 14 Sonoma: Control-click CP Remote, choose Open, then Open again.
- macOS 15 Sequoia and later (26, 27): Control-click no longer works. Open the app once and close the warning, then go to System Settings, Privacy & Security, scroll to Security, click Open Anyway for CP Remote and confirm. macOS may ask for your password.

**Local network (processors reached by IP address)**
- macOS 14: no permission is asked.
- macOS 15 and later: the first connection shows "CP Remote would like to find and connect to devices on your local network". Choose Allow.
- If you choose Don't Allow, or no prompt appears, CP Remote waits for your answer, opens System Settings on Local Network and shows a window with the steps: turn CP Remote on. It then connects by itself.
- If CP Remote is not in the list, quit it and open it again from Applications. From macOS 27.2 the list also has a + button to add it.
- macOS has no supported way to reset the choice. Because the app is ad-hoc signed, macOS may ask again after an update.

**Serial line (USB adapter)**
No permission is known to be needed. If the port cannot be opened, the connection log says why: `~/Library/Logs/CP Remote/connection.log` (Setup, Show Connection Log).

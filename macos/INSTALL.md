## Install and permissions

Open the disk image, drag CP Remote to Applications and open it from there. The app is ad-hoc signed and not notarized by Apple, so macOS asks for a permission or two. What happens depends on the macOS version.

**First open (Gatekeeper)**
- macOS 12 to 14: Control-click CP Remote, choose Open, then Open again.
- macOS 15 Sequoia and later (26, 27): Control-click no longer works. Open the app once and close the warning, then go to System Settings, Privacy & Security, scroll to Security, click Open Anyway for CP Remote and confirm. macOS may ask for your password.

**Local network (processors reached by IP address)**
- macOS 12 to 14: no permission is asked.
- macOS 15 and later: the first connection shows "CP Remote would like to find and connect to devices on your local network". Choose Allow.
- If you chose Don't Allow, turn CP Remote on in System Settings, Privacy & Security, Local Network. If CP Remote is not in the list, quit it and open it again from Applications.

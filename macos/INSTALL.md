## Install and permissions

Open the disk image, drag CP Remote to Applications and open it from there. The app is ad-hoc signed and not notarized by Apple, so macOS asks for a permission or two. What happens depends on the macOS version.

**First open (Gatekeeper)**
- macOS 14 Sonoma: Control-click CP Remote, choose Open, then Open again.
- macOS 15 Sequoia and later (26, 27): Control-click no longer works. Open the app once and close the warning, then go to System Settings, Privacy & Security, scroll to Security, click Open Anyway for CP Remote and confirm. macOS may ask for your password.

**Processor communication**
This version is interface-only: it shows the processor fronts but does not communicate with any processor, so it needs no network or serial permission.

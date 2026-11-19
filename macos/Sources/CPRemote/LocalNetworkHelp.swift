// The help shown when macOS blocks the local network: System Settings opens on
// Privacy & Security, Local Network, and a small floating window beside it
// says what to turn on. It closes by itself once the app connects.

import AppKit
import SwiftUI

@MainActor
enum LocalNetworkHelp {
    private static var panel: NSPanel?

    /// Open System Settings on the Local Network pane and show the steps in
    /// a floating window at the left of the screen, clear of the Settings
    /// window that macOS centres.
    static func show() {
        NSWorkspace.shared.open(RemoteModel.localNetworkSettings)
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Allow CP Remote on the local network"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: HelpView())
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.minX + 24, y: screen.maxY - 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Close the help window, if it is open.
    static func close() {
        panel?.close()
        panel = nil
    }

    /// What the help window says, for the macOS version it runs on. The
    /// Local Network permission exists from macOS 15; macOS 27.2 adds a way to
    /// add an app to the list by hand, and no version has a supported reset.
    struct Guidance: Equatable {
        let steps: [String]
        let note: String
    }

    static func guidance(for version: OperatingSystemVersion) -> Guidance {
        let canAddByHand = version.majorVersion > 27
            || (version.majorVersion == 27 && version.minorVersion >= 2)
        var steps = [
            "1. In the System Settings window that just opened, find CP Remote in the Local Network list.",
            "2. Turn CP Remote on.",
        ]
        if canAddByHand {
            steps.insert("   If CP Remote is not in the list, click + and add it from Applications.", at: 1)
        }
        steps.append("3. Come back to CP Remote: it connects by itself, and this window closes.")
        var note = "If System Settings shows Privacy & Security instead, click Local Network first."
        if !canAddByHand {
            note += " If CP Remote is not in the list, quit it and open it again from Applications: macOS adds it when the app tries to connect."
        }
        note += " Each new version of CP Remote may have to be allowed again."
        return Guidance(steps: steps, note: note)
    }

    private static var current: Guidance {
        guidance(for: ProcessInfo.processInfo.operatingSystemVersion)
    }

    private struct HelpView: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("macOS is blocking CP Remote from reaching the processor.")
                    .font(.headline)
                ForEach(LocalNetworkHelp.current.steps, id: \.self) { Text($0) }
                Text(LocalNetworkHelp.current.note)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open System Settings Again") {
                        NSWorkspace.shared.open(RemoteModel.localNetworkSettings)
                    }
                    Spacer()
                    Button("Close") { LocalNetworkHelp.close() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(width: 340)
        }
    }
}

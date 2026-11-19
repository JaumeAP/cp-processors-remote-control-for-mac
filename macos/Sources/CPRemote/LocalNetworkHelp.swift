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

    private static let steps = [
        "1. In the System Settings window that just opened, find CP Remote in the Local Network list.",
        "2. Turn CP Remote on.",
        "3. Come back to CP Remote: it connects by itself, and this window closes.",
    ]
    private static let note = "If System Settings shows Privacy & Security instead, click Local Network first. Each new version of CP Remote may have to be allowed again."

    private struct HelpView: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("macOS is blocking CP Remote from reaching the processor.")
                    .font(.headline)
                ForEach(LocalNetworkHelp.steps, id: \.self) { Text($0) }
                Text(LocalNetworkHelp.note)
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

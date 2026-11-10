// Entry point of CP Remote: one window showing the front panel of the chosen processor, and
// a Setup menu for the processor's IP address.

import AppKit
import SwiftUI

@main
struct CPRemoteApp: App {
    @StateObject private var model = RemoteModel()

    init() {
        // Run as a regular app (menu bar, Dock icon) even from `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("CP Remote", id: "main") {
            FrontPanelView(model: model)
                .sheet(isPresented: $model.showSetup) { SetupView(model: model) }
                .task {
                    NSApplication.shared.activate()
                    await model.connect()   // with no address saved, opens Setup
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Setup") {
                Button("Processor IP…") { model.showSetup = true }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
                Button("Reconnect") { Task { await model.reconnect() } }
                    .keyboardShortcut("r")
                Button("Disconnect") { Task { await model.disconnect() } }
            }
        }
    }
}

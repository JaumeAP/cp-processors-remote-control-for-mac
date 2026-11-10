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
        Self.logAppAndWindowEvents()
    }

    /// Note in the connection log when the app gains or loses focus and when
    /// its window is key, covered or about to move: clicks outside the
    /// buttons show up as these events, and they are what a lost connection
    /// has to be compared with.
    private static func logAppAndWindowEvents() {
        let log = ConnectionLog.shared
        let info = ProcessInfo.processInfo
        log.write("start: CP Remote \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unversioned"), "
                  + "macOS \(info.operatingSystemVersionString)")
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.willMoveNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                var detail = ""
                if let window = notification.object as? NSWindow {
                    let visible = MainActor.assumeIsolated { window.occlusionState.contains(.visible) }
                    detail = " (window \(visible ? "visible" : "covered"))"
                }
                log.write("ui: \(notification.name.rawValue)\(detail)")
            }
        }
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
            CommandMenu("Level") {
                Button("Level Up") { model.stepKnob(up: true) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.isConnected)
                Button("Level Down") { model.stepKnob(up: false) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(!model.isConnected)
                Button("Reference 7.0") { model.setReference() }
                    .keyboardShortcut("0")
                    .disabled(!model.isConnected)
            }
            CommandMenu("Setup") {
                Button("Processor IP…") { model.showSetup = true }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
                Button("Reconnect") { Task { await model.reconnect() } }
                    .keyboardShortcut("r")
                Button("Disconnect") { Task { await model.disconnect() } }
                Divider()
                Button("Show Connection Log") {
                    ConnectionLog.shared.flush()
                    NSWorkspace.shared.activateFileViewerSelecting([ConnectionLog.shared.url])
                }
            }
        }
    }
}

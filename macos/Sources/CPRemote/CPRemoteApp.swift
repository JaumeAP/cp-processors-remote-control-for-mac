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
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unversioned"
        log.write(
            "start: CP Remote \(version), "
                + "macOS \(info.operatingSystemVersionString)")
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.willMoveNotification,
        ]
        // At quit, the lines still queued would be lost: write them first.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            log.write("quit")
            log.flush()
        }
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

    private static let moveToApplicationsMessage =
        "CP Remote is running from the disk image or from the folder it was downloaded to. "
        + "a copy run from the disk image is gone once the image is ejected, and macOS may treat "
        + "the app as a new one and ask again for its permissions. Quit it, drag CP Remote to the "
        + "Applications folder and open it from there."

    var body: some Scene {
        WindowGroup("CP Remote", id: "main") {
            FrontPanelView(model: model)
                .sheet(isPresented: $model.showSetup) { SetupView(model: model) }
                .alert("Move CP Remote to Applications", isPresented: $model.showMoveToApplicationsAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(Self.moveToApplicationsMessage)
                }
                .task {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    await model.connect()  // with no address saved, opens Setup
                }
        }
        .windowStyle(.hiddenTitleBar)
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
                Divider()
                Toggle(
                    "Show Level in dB",
                    isOn: Binding(
                        get: { model.levelInDecibels },
                        set: { _ in model.toggleLevelUnit() })
                )
                .keyboardShortcut("d")
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

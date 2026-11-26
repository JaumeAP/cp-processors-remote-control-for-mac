// The link's lifecycle: connect, reconnect and disconnect (one at a time), the
// Test check of an address, and the sending of control changes.

import AppKit
import Foundation

extension RemoteModel {
    /// Drop any link and open a fresh one to `host`. With no address saved,
    /// open Setup.
    func connect() async { await serialized { await self.connectNow() } }

    /// Reopen the current link when it is to the same address and model;
    /// otherwise a fresh connect.
    func reconnect() async { await serialized { await self.reconnectNow() } }

    func disconnect() async { await serialized { await self.disconnectNow() } }

    /// Check the processor at `address`, as `chosen` (the model picked in
    /// Setup, not yet saved; the saved one when nil). When the main link is
    /// to that address and model, ask over it (the CP650 serves one control
    /// client); otherwise open a short-lived second link.
    func test(address raw: String, model chosen: ProcessorModel? = nil) async -> String {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return "Type an IP address first." }
        let model = chosen ?? processorModel
        let name = Self.choiceName(model)
        if let link = processor, processorHost == address, link.model == model {
            guard let level = Self.faderLevel(await link.get(model.panel.fader)) else {
                return "Connected to \(address), but no fader reply."
            }
            return "OK: the connected \(name) at \(address) answered, fader \(Self.faderText(level))."
        }
        let link = ProcessorLink(host: address, port: port, model: model)
        await pauseAfterClose(address, link.port, model: model)
        guard await link.connect() else {
            await link.disconnect()
            return "No connection to \(address) on port \(link.port)."
        }
        let reply = await link.get(model.panel.fader)
        await link.disconnect()
        Self.closed(address, link.port, model: model)
        guard let level = Self.faderLevel(reply) else {
            return "Connected to \(address):\(link.port), but no fader reply."
        }
        return "OK: the \(name) at \(address) answered, fader \(Self.faderText(level))."
    }

    /// Note that a session to `address` was just closed (CP650 only).
    static func closed(_ address: String, _ port: UInt16, model: ProcessorModel) {
        if model == .cp650 { cp650Closes["\(address):\(port)"] = .now }
    }

    /// Wait out what is left of the CP650's reopen pause since this app last
    /// closed a session to `address`.
    func pauseAfterClose(_ address: String, _ port: UInt16, model: ProcessorModel) async {
        guard model == .cp650, let closed = Self.cp650Closes["\(address):\(port)"] else { return }
        let left = (closed + reopenPause) - Monotonic.Instant.now
        await Monotonic.sleep(for: left)
    }

    func serialized(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
        let previous = lifecycle
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        lifecycle = task
        await task.value
    }

    func connectNow() async {
        await disconnectNow()
        let address = trimmedHost
        guard !address.isEmpty else {
            showSetup = true
            return
        }
        let link = ProcessorLink(host: address, port: port, model: processorModel)
        note("connect to \(address):\(link.port) as \(processorModel.rawValue)")
        processor = link
        processorHost = address
        linkOpened = false
        localChange = [:]
        sending = [:]
        formatListDue = true
        resetMacroReads()
        silentPolls = 0
        // A new processor: nothing shown may be the previous unit's.
        macroName = nil
        macroNameNumber = nil
        macroPreset = nil
        macros = nil
        muted = false
        formatButton = nil
        programmedFormats = nil
        panelRead = false
        announceConnectionChange()
        // A CP650 session this app closed a moment ago (the main link, a
        // Test link) may still hold the unit's one connection.
        await pauseAfterClose(address, link.port, model: processorModel)
        guard processor === link else { return }
        linkOpened = await link.connect()
        guard processor === link else { return }
        if !linkOpened { note("no answer from \(address) at connect (\(await link.lastError)): the poll retries") }
        startPolling(link)
    }

    /// Close the link and open it again. The CP650 takes one connection, so
    /// its old session is closed, recorded and given the reopen pause before
    /// the new one opens. Other models keep the library's own reconnect, which
    /// keeps the queued sends.
    func reopenLink(_ link: ProcessorLink) async -> Bool {
        guard link.model == .cp650 else { return await link.reconnect() }
        await link.disconnect()
        Self.closed(link.host, link.port, model: link.model)
        await pauseAfterClose(link.host, link.port, model: link.model)
        return await link.connect()
    }

    func reconnectNow() async {
        guard let link = processor, processorHost == trimmedHost, link.model == processorModel else {
            return await connectNow()
        }
        note("reconnect requested")
        markUnread("reconnect requested")
        formatListDue = true
        resetMacroReads()
        linkOpened = await reopenLink(link)
        guard processor === link else { return }
        if !linkOpened { note("reconnect failed: \(await link.lastError)") }
    }

    func disconnectNow() async {
        pollTask?.cancel()
        pollTask = nil
        pendingFader = nil
        endKnobTurn()
        guard let link = processor else { return }
        note("disconnect requested")
        let closedHost = processorHost
        processor = nil
        processorHost = nil
        // Nothing of the old unit may show or count after the disconnect.
        muted = false
        formatButton = nil
        localChange = [:]
        sending = [:]
        silentPolls = 0
        programmedFormats = nil
        macroName = nil
        macroNameNumber = nil
        macroPreset = nil
        macros = nil
        panelRead = false
        announceConnectionChange()
        await link.disconnect()
        if let closedHost { Self.closed(closedHost, link.port, model: link.model) }
    }

    /// Disable the controls until the panel has been read again on the
    /// current link, end a knob turn, and tell VoiceOver.
    func markUnread(_ why: String) {
        endKnobTurn()
        guard panelRead else { return }
        panelRead = false
        note("controls disabled: \(why)")
        announceConnectionChange()
    }

    func announceConnectionChange() {
        guard isConnected != announcedConnected else { return }
        announcedConnected = isConnected
        let text = isConnected ? "Processor connected" : "Processor not answering; controls disabled"
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    /// Send one control change, marking the control as changed here and as
    /// being sent until the send is through, so a poll reply from before it
    /// does not overwrite it.
    func send(_ param: String, on link: ProcessorLink, _ operation: @escaping @Sendable () async -> Bool) {
        localChange[param] = .now
        sending[param, default: 0] += 1
        Task {
            let delivered = await operation()
            // A send from an earlier link finishes after a reconnect has reset
            // the counters: it must not change the current link's counters.
            if processor === link {
                sending[param, default: 1] -= 1
                if sending[param] == 0 { sending[param] = nil }
            }
            if !delivered, processor === link { note("\(param) not sent: \(await link.lastError)") }
        }
    }

    /// Send the latest fader value, one send at a time, so a knob turn sends
    /// only the newest level rather than every step.
    func pumpFader() {
        guard isConnected else {
            pendingFader = nil  // the panel is unread: never send a level from before
            return
        }
        guard !faderInFlight, let value = pendingFader, let link = processor else { return }
        pendingFader = nil
        faderInFlight = true
        let param = processorModel.panel.fader
        Task {
            if !(await link.set(param, value)), processor === link {
                note("\(param) not sent: \(await link.lastError)")
            }
            faderInFlight = false
            pumpFader()
        }
    }
}

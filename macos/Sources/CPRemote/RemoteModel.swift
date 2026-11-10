// The app's live state: one DolbyCP link to the CP650 at the configured
// address, the fader level, the selected format button and the mute flag.

import CPx50Comms
import Foundation
import SwiftUI

/// The parameter names one processor model uses on its front panel, as its
/// manual gives them: CP650 `fader_level`, `mute`, `format_button`; CP750
/// `cp750.sys.fader`, `cp750.sys.mute`, `cp750.sys.input_mode`; CP950
/// `sys.fader`, `sys.mute` (its front has no input buttons; its macros are
/// `sys.macro_preset`, not on this panel).
struct PanelProfile {
    let fader: String
    let mute: String
    /// Input selection: the value each front button sends, in button order
    /// (CP750 only).
    let inputs: [String]?
    /// Lowest value the fader takes on the wire, in tenths (CP950: 1 to 100).
    let faderMinimum: Int
}

extension ProcessorModel {
    var panel: PanelProfile {
        switch self {
        case .cp650:
            PanelProfile(fader: "fader_level", mute: "mute", inputs: nil, faderMinimum: 0)
        case .cp750:
            PanelProfile(fader: "cp750.sys.fader", mute: "cp750.sys.mute",
                         inputs: ["dig_1", "dig_2", "dig_3", "dig_4", "analog", "non_sync", "mic"],
                         faderMinimum: 0)
        case .cp850, .cp950, .cp950a:
            PanelProfile(fader: "sys.fader", mute: "sys.mute", inputs: nil, faderMinimum: 1)
        }
    }
}

@MainActor
final class RemoteModel: ObservableObject {
    /// The generic silkscreen on the eight format buttons (CP650 user's
    /// manual, figure 2-1); fixed, whatever formats are programmed.
    static let buttonSilkscreen = ["01", "04", "05", "10", "11", "U1", "U2", "NS"]
    /// The fader runs 0.0 to 10.0; the wire carries tenths (`70` is 7.0).
    static let faderRange: ClosedRange<Double> = 0...10
    /// The knob is an endless encoder: three full turns run the fader from
    /// 0.0 to 10.0, so one degree is 1/108 of a unit. It has no end stops:
    /// past 0.0 or 10.0 it keeps turning and the fader stays at the limit.
    static let degreesPerUnit = 3 * 360 / (faderRange.upperBound - faderRange.lowerBound)
    /// How long a control changed here is shielded from poll replies: a reply
    /// read since shortly before the change may predate it on the processor.
    private static let pollHoldOff: Duration = .milliseconds(1500)
    /// Unanswered fader reads in a row after which a link that is still open
    /// is closed and opened again (a hung control session).
    private static let silentPollLimit = 2
    /// How long a SET may wait for its reply. The client's default, 0.5 s, is
    /// too short for a real unit: a mute fades and a format change reconfigures
    /// it, and a reply slower than the timeout is taken as a lost link, which
    /// disables the controls for seconds.
    private static let setReplyTimeout: Double = 3
    private static let hostKey = "processorHost"
    private static let modelKey = "processorModel"
    /// The models the Setup menu offers. CP850 and CP950 share one front.
    static let choices: [ProcessorModel] = [.cp650, .cp750, .cp950]

    @Published var host: String {
        didSet { defaults.set(host, forKey: Self.hostKey) }
    }
    @Published var showSetup = false
    /// The processor model: its front panel, its wire names and its controls.
    /// The fader and mute are live on every model; the front-panel buttons
    /// follow the model's profile (the CP750's inputs, the CP650's formats).
    @Published private(set) var processorModel: ProcessorModel
    @Published private(set) var fader: Double = 7.0
    @Published private(set) var formatButton: Int?
    /// The format number programmed on each button, from the processor's
    /// `format_list`; nil until it reports eight entries.
    @Published private(set) var programmedFormats: [String]?
    @Published private(set) var muted = false
    @Published private(set) var status: ProcessorStatus = .missing
    @Published private(set) var message = "Not connected"
    /// The fader has been read on the current link. Until then the controls
    /// stay disabled, so a first touch never starts from a stale level.
    @Published private(set) var panelRead = false
    /// The knob's drawn rotation, in degrees, free of the fader's limits.
    @Published private(set) var knobRotation: Double = 0

    /// The unrounded fader value during a turn, so slow turns add up.
    private var knobValue: Double?
    var isTurningKnob: Bool { knobValue != nil }

    private var processor: DolbyCP?
    /// The address `processor` was built for.
    private var processorHost: String?
    private var statusTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// The tail of the connect/reconnect/disconnect chain: each waits for the
    /// one before, so two of them never interleave.
    private var lifecycle: Task<Void, Never>?
    private var pendingFader: Int?
    private var faderInFlight = false
    /// When each control was last changed here.
    private var localChange: [String: ContinuousClock.Instant] = [:]
    /// `format_list` is read once per opened link.
    private var formatListDue = true
    private var silentPolls = 0
    /// Hung links reopened (for tests).
    private(set) var linkReopens = 0
    private var announcedConnected = false

    /// Where the IP address is kept, and the TCP port (nil: the CP650's
    /// 61412). Both are injectable so tests use their own and a simulator.
    private let defaults: UserDefaults
    let port: UInt16?

    /// Where the app and its link write their events; nil for none (tests).
    private let log: ConnectionLog?

    init(defaults: UserDefaults = .standard, port: UInt16? = nil, log: ConnectionLog? = .shared) {
        self.defaults = defaults
        self.port = port
        self.log = log
        host = defaults.string(forKey: Self.hostKey) ?? ""
        processorModel = defaults.string(forKey: Self.modelKey)
            .flatMap { try? ProcessorModel(name: $0) } ?? .cp650
    }

    /// Choose the processor model and remember it. Takes effect at connect.
    func choose(_ model: ProcessorModel) {
        processorModel = model
        defaults.set(model.rawValue, forKey: Self.modelKey)
    }

    /// No fader value waiting to be handed to the client or being handed.
    var faderIsSettled: Bool { pendingFader == nil && !faderInFlight }

    /// The controls work: a link, answering, and the panel read on it.
    var isConnected: Bool { processor != nil && status == .ok && panelRead }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Connection

    /// Drop any link and open a fresh one to `host`.
    func connect() async { await serialized { await self.connectNow() } }

    /// Reopen the current link, keeping its queued commands, when it is to
    /// the same address; otherwise a fresh connect.
    func reconnect() async { await serialized { await self.reconnectNow() } }

    func disconnect() async { await serialized { await self.disconnectNow() } }

    /// Check the processor at `address`. When the main link is up to that
    /// address, ask over it (the CP650 serves one control client); otherwise
    /// open a short-lived second link.
    func test(address raw: String) async -> String {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return "Type an IP address first." }
        let model = processorModel
        let port = self.port ?? model.defaultPort
        if let cp = processor, processorHost == address, status == .ok, cp.model == model {
            guard let level = Self.faderLevel(try? await cp.get(model.panel.fader)) else {
                return "Connected to \(address), but no fader reply."
            }
            return "OK: the connected CP650 at \(address) answered, fader \(Self.faderText(level))."
        }
        let cp = DolbyCP(host: address, port: port, model: model)
        guard await cp.connect() else {
            await cp.disconnect()
            return "No connection to \(address) on port \(port)."
        }
        let reply = try? await cp.get(model.panel.fader)
        await cp.disconnect()
        guard let level = Self.faderLevel(reply) else {
            return "Connected to \(address):\(port), but no fader reply."
        }
        return "OK: the CP650 at \(address) answered, fader \(Self.faderText(level))."
    }

    // MARK: - Controls

    func setFader(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = Self.clampFader(value)
        let tenths = max(Int((clamped * 10).rounded()), processorModel.panel.faderMinimum)
        guard Double(tenths) / 10 != fader || pendingFader != nil else { return }
        fader = Double(tenths) / 10
        localChange[processorModel.panel.fader] = .now
        pendingFader = tenths
        pumpFader()
    }

    func beginKnobTurn() { knobValue = fader }

    func endKnobTurn() { knobValue = nil }

    /// Turn the knob by `degrees` (clockwise positive) and move the fader by
    /// `degrees / degreesPerUnit`, held within 0.0 to 10.0.
    func turnKnob(byDegrees degrees: Double) {
        guard degrees.isFinite else { return }
        knobRotation += degrees
        let next = min(max((knobValue ?? fader) + degrees / Self.degreesPerUnit,
                           Self.faderRange.lowerBound), Self.faderRange.upperBound)
        if knobValue != nil { knobValue = next }
        setFader(next)
    }

    /// One 0.1 step of the knob (arrow keys, VoiceOver).
    func stepKnob(up: Bool) { turnKnob(byDegrees: (up ? 0.1 : -0.1) * Self.degreesPerUnit) }

    /// A front-panel button: the CP650's format buttons (`format_button`), or
    /// the CP750's input buttons (`cp750.sys.input_mode`).
    func pressButton(_ button: Int) {
        guard let cp = processor, isConnected else { return }
        formatButton = button
        if let inputs = processorModel.panel.inputs {
            guard inputs.indices.contains(button - 1) else { return }
            localChange[Self.inputParam] = .now
            let value = inputs[button - 1]
            Task { _ = try? await cp.set(Self.inputParam, .string(value), timeout: Self.setReplyTimeout) }
        } else {
            localChange["format_button"] = .now
            Task { _ = try? await cp.set("format_button", .int(button), timeout: Self.setReplyTimeout) }
        }
    }

    static let inputParam = "cp750.sys.input_mode"

    func toggleMute() {
        guard let cp = processor, isConnected else { return }
        muted.toggle()
        localChange[processorModel.panel.mute] = .now
        let value = muted ? 1 : 0
        Task { _ = try? await cp.set(processorModel.panel.mute, .int(value), timeout: Self.setReplyTimeout) }
    }

    static func faderText(_ value: Double) -> String { String(format: "%.1f", value) }

    /// The name shown for a choice in Setup.
    static func choiceName(_ model: ProcessorModel) -> String {
        model == .cp950 ? "CP850 / CP950" : model.rawValue
    }

    /// Names of the standard Dolby cinema formats (CP650 user's manual);
    /// a number not listed has no name shown.
    static let formatNames = [
        "01": "Mono", "04": "Dolby A-Type", "05": "Dolby SR", "10": "Dolby Digital",
        "11": "External 6-channel", "60": "Nonsync",
    ]

    /// The CP750's selected input, by its name on the front.
    var currentInputName: String {
        guard let button = formatButton, (1...7).contains(button) else { return "Input --" }
        return ["Digital 1", "Digital 2", "Digital 3", "Digital 4", "Multi-Ch Analog", "NonSync", "Mic"][button - 1]
    }

    /// The selected button's programmed format number, or nil (CP650 only).
    var currentFormat: String? {
        guard let button = formatButton, (1...8).contains(button) else { return nil }
        return programmedFormats?[button - 1]
    }

    // MARK: - Lifecycle (serialized)

    private func serialized(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
        let previous = lifecycle
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        lifecycle = task
        await task.value
    }

    /// One line in the connection log.
    private func note(_ text: String) {
        log?.write("app: \(text)")
    }

    private func connectNow() async {
        await disconnectNow()
        let address = trimmedHost
        guard !address.isEmpty else {
            message = "Set the processor IP in Setup"
            showSetup = true
            return
        }
        let cp = DolbyCP(host: address, port: port, model: processorModel, autoReconnect: true)
        note("connect to \(address) as \(processorModel.rawValue)")
        if let log { await cp.setEventLog { line in log.write("link: \(line)") } }
        processor = cp
        processorHost = address
        localChange = [:]
        formatListDue = true
        silentPolls = 0
        message = "Connecting to \(address)…"
        statusTask = Task { [weak self] in
            for await value in cp.statusUpdates {
                guard let self, self.processor === cp else { return }
                self.apply(status: value)
            }
        }
        let ok = await cp.connect()
        guard processor === cp else { return }
        apply(status: await cp.status)
        if !ok { message = "No answer from \(address), retrying…" }
        startPolling(cp)
    }

    private func reconnectNow() async {
        guard let cp = processor, processorHost == trimmedHost, cp.model == processorModel else {
            return await connectNow()
        }
        note("reconnect requested")
        message = "Reconnecting to \(trimmedHost)…"
        panelRead = false
        formatListDue = true
        _ = await cp.reconnect()
        guard processor === cp else { return }
        apply(status: await cp.status)
    }

    private func disconnectNow() async {
        pollTask?.cancel()
        statusTask?.cancel()
        pollTask = nil
        statusTask = nil
        pendingFader = nil
        endKnobTurn()
        guard let cp = processor else { return }
        note("disconnect requested")
        processor = nil
        processorHost = nil
        programmedFormats = nil
        apply(status: .missing)
        message = "Not connected"
        await cp.disconnect()
    }

    /// Record a status change: a link that stops answering disables the
    /// controls until the panel has been read again, ends a knob turn, and
    /// is announced to VoiceOver.
    private func apply(status value: ProcessorStatus) {
        note("status \(value), panel read \(panelRead)")
        status = value
        if value != .ok {
            panelRead = false
            endKnobTurn()
        }
        if let address = processorHost {
            message = value == .ok ? "Connected to \(address)" : "Lost \(address), retrying…"
        }
        announceConnectionChange()
    }

    private func announceConnectionChange() {
        guard isConnected != announcedConnected else { return }
        announcedConnected = isConnected
        let text = isConnected ? "Processor connected" : "Processor not answering; controls disabled"
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: - Fader hand-off

    /// Hand the latest fader value to the client, one hand-off at a time, so
    /// the SETs reach its queue in the order they were made (the queue then
    /// coalesces them to the newest).
    private func pumpFader() {
        guard !faderInFlight, let value = pendingFader, let cp = processor else { return }
        pendingFader = nil
        faderInFlight = true
        Task {
            _ = try? await cp.set(processorModel.panel.fader, .int(value), timeout: Self.setReplyTimeout)
            faderInFlight = false
            pumpFader()
        }
    }

    // MARK: - Polling

    private func startPolling(_ cp: DolbyCP) {
        pollTask = Task { [weak self] in
            // Read at once, then every two seconds; connect() does not wait
            // for it, so a link that never answers still shows its state.
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollCycle(cp)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func isCurrent(_ cp: DolbyCP) -> Bool { processor === cp && !Task.isCancelled }

    private func pollCycle(_ cp: DolbyCP) async {
        guard isCurrent(cp) else { return }
        let linkIsUp = await cp.isLinkUp
        // The app may have disconnected while the client was asked.
        guard isCurrent(cp) else { return }
        if !linkIsUp {
            // The client's own watchdog runs only after a successful
            // connect: retry here, so a processor that was off, booting or
            // unreachable at connect time is found when it comes up.
            note("link is down: reconnecting")
            let ok = await cp.reconnect()
            note("reconnect \(ok ? "succeeded" : "failed")")
            guard isCurrent(cp), ok else { return }
            formatListDue = true
        }
        await refresh(cp)
    }

    /// A reply to a read that started at `start` may update the panel only
    /// if no SET of that control is queued or being sent, and the control was
    /// not changed here since just before the read. The change time is read
    /// after the client hops, so a change made during them counts.
    private func mayApply(_ param: String, readStartedAt start: ContinuousClock.Instant,
                          on cp: DolbyCP) async -> Bool {
        if await cp.pendingSets.contains(where: { $0.param == param }) { return false }
        if await cp.inflightSet?.param == param { return false }
        if let changed = localChange[param], changed > start - Self.pollHoldOff { return false }
        return true
    }

    private func refresh(_ cp: DolbyCP) async {
        let panel = processorModel.panel
        var start = ContinuousClock.now
        let faderReply = try? await cp.get(panel.fader)
        guard isCurrent(cp) else { return }
        guard let faderReply else {
            // Unanswered: after a few in a row, reopen a link that is open
            // but hung, and skip the other reads (each would time out too).
            silentPolls += 1
            note("fader read unanswered (\(silentPolls) of \(Self.silentPollLimit))")
            if silentPolls >= Self.silentPollLimit {
                note("reopening the link: \(Self.silentPollLimit) fader reads unanswered")
                silentPolls = 0
                formatListDue = true
                linkReopens += 1
                _ = await cp.reconnect()
            }
            return
        }
        silentPolls = 0
        if let level = Self.faderLevel(faderReply) {
            if await mayApply(panel.fader, readStartedAt: start, on: cp), isCurrent(cp),
               !isTurningKnob, faderIsSettled, fader != level {
                fader = level
            }
            if isCurrent(cp), !panelRead {
                panelRead = true
                note("panel read: controls enabled")
                announceConnectionChange()
            }
        }

        // The selected button: the CP650's format button, or the CP750's input.
        start = .now
        if processorModel == .cp650 {
            if let reply = try? await cp.get("format_button"), isCurrent(cp),
               let button = Int(reply),
               await mayApply("format_button", readStartedAt: start, on: cp), isCurrent(cp),
               formatButton != button {
                formatButton = button
            }
        } else if panel.inputs != nil, let reply = try? await cp.get(Self.inputParam), isCurrent(cp),
                  let index = panel.inputs?.firstIndex(of: reply),
                  await mayApply(Self.inputParam, readStartedAt: start, on: cp), isCurrent(cp),
                  formatButton != index + 1 {
            formatButton = index + 1
        }

        start = .now
        if let reply = try? await cp.get(panel.mute), isCurrent(cp),
           await mayApply(panel.mute, readStartedAt: start, on: cp), isCurrent(cp),
           muted != (reply == "1") {
            muted = reply == "1"
        }

        // The CP650's programmed formats change only in setup: one attempt
        // per opened link, so a processor that never answers it is not asked
        // again.
        guard processorModel == .cp650, formatListDue, isCurrent(cp) else { return }
        formatListDue = false
        if let reply = try? await cp.get("format_list"), isCurrent(cp) {
            let labels = reply.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if labels.count == 8, labels.allSatisfy({ !$0.isEmpty }) { programmedFormats = labels }
        }
    }

    // MARK: - Values

    /// A fader reply in tenths as a level, held within 0.0 to 10.0; nil when
    /// it is not a finite number (`nan`, `inf`, text).
    static func faderLevel(_ reply: String?) -> Double? {
        guard let reply, let tenths = Double(reply), tenths.isFinite else { return nil }
        return clampFader(tenths / 10)
    }

    private static func clampFader(_ value: Double) -> Double {
        min(max((value * 10).rounded() / 10, faderRange.lowerBound), faderRange.upperBound)
    }
}

extension ProcessorModel {
    /// Width over height of the front panel, as the manual draws it.
    var aspect: CGFloat {
        switch self {
        case .cp650: panelAspect
        case .cp750: 935 / 180
        case .cp850, .cp950, .cp950a: 890 / 242
        }
    }
}

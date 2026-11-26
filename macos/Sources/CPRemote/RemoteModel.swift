// The app's live state: one link to the processor at the configured address
// (`ProcessorLink`, over the released cpseries library), the fader level, the
// selected front-panel button, the mute flag and the macro.

import Foundation
import SwiftUI

/// The parameter names one processor model uses on its front panel, as its
/// manual gives them: CP650 `fader_level`, `mute`, `format_button`; CP750
/// `cp750.sys.fader`, `cp750.sys.mute`, `cp750.sys.input_mode`; CP850 / CP950
/// / CP950A `sys.fader`, `sys.mute` (no input buttons; the macro is
/// `sys.macro_preset`, named by `sys.macro_name`).
struct PanelProfile {
    let fader: String
    let mute: String
    /// Input selection: the value each front button sends, in button order
    /// (CP750 only).
    let inputs: [String]?
    /// Lowest value the fader takes on the wire, in tenths (CP950: 1 to 100).
    let faderMinimum: Int
    /// The parameter that names the selected macro, shown on the screen
    /// (CP850 / CP950 / CP950A).
    var macroName: String? = nil
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
            PanelProfile(fader: "sys.fader", mute: "sys.mute", inputs: nil, faderMinimum: 1,
                         macroName: "sys.macro_name")
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
    private static let pollHoldOff: TimeInterval = 1.5
    /// Unanswered fader reads in a row after which the link is closed and
    /// opened again (a hung control session).
    private static let silentPollLimit = 2
    /// Seconds between two reads of the panel.
    private static let pollInterval: TimeInterval = 2
    private static let hostKey = "processorHost"
    private static let modelKey = "processorModel"
    /// The models the Setup menu offers. The CP950 choice covers the CP950A
    /// (one front, one protocol).
    static let choices: [ProcessorModel] = [.cp650, .cp750, .cp850, .cp950]

    @Published var host: String {
        didSet { defaults.set(host, forKey: Self.hostKey) }
    }
    @Published var showSetup = false
    /// The app runs from the disk image or from a translocated copy (opened
    /// in place from Downloads): it should be in Applications.
    @Published var showMoveToApplicationsAlert = RemoteModel.runsOutsideApplications(Bundle.main.bundlePath)

    /// True for a bundle path on a mounted disk image or under App
    /// Translocation's randomized read-only copy.
    nonisolated static func runsOutsideApplications(_ path: String) -> Bool {
        path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }

    /// The processor model: its front panel, its wire names and its controls.
    @Published private(set) var processorModel: ProcessorModel
    @Published private(set) var fader: Double = 7.0
    @Published private(set) var formatButton: Int?
    /// The format number programmed on each button, from the processor's
    /// `format_list`; nil until it reports eight entries.
    @Published private(set) var programmedFormats: [String]?
    /// The selected macro's name, read from the processor (CP850 / CP950 / CP950A).
    @Published private(set) var macroName: String?
    @Published private(set) var macroPreset: Int?
    /// The macros the processor offers, in its order (CP850 / CP950 / CP950A).
    /// Not read in this build: the list is a multi-line reply, which the
    /// cpseries library does not return.
    @Published private(set) var macros: [Macro]?
    /// Unanswered macro reads in a row; at `macroMissLimit` the macro reads
    /// pause for `macroPausePolls` polls (each miss costs a read timeout),
    /// then are tried again. Any answered macro read clears it.
    private var macroMisses = 0
    private var macroPollsToSkip = 0
    private static let macroMissLimit = 2
    private static let macroPausePolls = 5
    /// The macro number `macroName` belongs to; nil when no name is known.
    private var macroNameNumber: Int?

    struct Macro: Equatable, Sendable {
        let number: Int
        let name: String
    }

    static let macroPresetParam = "sys.macro_preset"
    static let inputParam = "cp750.sys.input_mode"
    static let formatButtonParam = "format_button"

    /// Show the level in decibels (7.0 is 0 dB) instead of the fader number.
    @Published private(set) var levelInDecibels = false
    private static let decibelsKey = "levelInDecibels"
    @Published private(set) var muted = false
    /// The fader and the mute have been read on the current link. Until then
    /// the controls stay disabled, so a first touch never starts from a stale
    /// level.
    @Published private(set) var panelRead = false
    /// The knob's drawn rotation, in degrees, free of the fader's limits.
    @Published private(set) var knobRotation: Double = 0

    /// The unrounded fader value during a turn, so slow turns add up.
    private var knobValue: Double?
    var isTurningKnob: Bool { knobValue != nil }

    private var processor: ProcessorLink?
    /// The address `processor` was built for.
    private var processorHost: String?
    /// The link has been opened once; until then each poll tries to open it.
    private var linkOpened = false
    private var pollTask: Task<Void, Never>?
    /// The tail of the connect/reconnect/disconnect chain: each waits for the
    /// one before, so two of them never interleave.
    private var lifecycle: Task<Void, Never>?
    private var pendingFader: Int?
    private var faderInFlight = false
    /// When each control was last changed here.
    private var localChange: [String: Monotonic.Instant] = [:]
    /// Sends of each control not yet through.
    private var sending: [String: Int] = [:]
    /// `format_list` is read once per opened link.
    private var formatListDue = true
    private var silentPolls = 0
    /// Hung links reopened (for tests).
    private(set) var linkReopens = 0
    private var announcedConnected = false

    /// Where the IP address is kept, and the TCP port (nil: the model's own).
    /// Both are injectable so tests use their own and a simulator.
    private let defaults: UserDefaults
    let port: UInt16?

    /// Where the app writes its events; nil for none (tests).
    private let log: ConnectionLog?

    /// The CP650's reopen pause, `cp650ReopenPause` unless a test sets it.
    let reopenPause: Double

    init(defaults: UserDefaults = .standard, port: UInt16? = nil, log: ConnectionLog? = .shared,
         reopenPause: Double = RemoteModel.cp650ReopenPause) {
        self.defaults = defaults
        self.port = port
        self.log = log
        self.reopenPause = reopenPause
        host = defaults.string(forKey: Self.hostKey) ?? ""
        levelInDecibels = defaults.bool(forKey: Self.decibelsKey)
        processorModel = defaults.string(forKey: Self.modelKey)
            .flatMap { ProcessorModel(rawValue: $0) } ?? .cp650
    }

    /// Choose the processor model and remember it. Takes effect at connect.
    func choose(_ model: ProcessorModel) {
        processorModel = model
        defaults.set(model.rawValue, forKey: Self.modelKey)
    }

    /// No fader value waiting to be sent or being sent.
    var faderIsSettled: Bool { pendingFader == nil && !faderInFlight }

    /// The controls work: a link with the panel read on it. One exchange
    /// without a reply does not disable them; a fader read unanswered through
    /// all the library's retries does (`markUnread`).
    var isConnected: Bool { processor != nil && panelRead }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Connection

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
        if let cp = processor, processorHost == address, cp.model == model {
            guard let level = Self.faderLevel(await cp.get(model.panel.fader)) else {
                return "Connected to \(address), but no fader reply."
            }
            return "OK: the connected \(name) at \(address) answered, fader \(Self.faderText(level))."
        }
        let cp = ProcessorLink(host: address, port: port, model: model)
        await pauseAfterClose(address, cp.port, model: model)
        guard await cp.connect() else {
            await cp.disconnect()
            return "No connection to \(address) on port \(cp.port)."
        }
        let reply = await cp.get(model.panel.fader)
        await cp.disconnect()
        Self.closed(address, cp.port, model: model)
        guard let level = Self.faderLevel(reply) else {
            return "Connected to \(address):\(cp.port), but no fader reply."
        }
        return "OK: the \(name) at \(address) answered, fader \(Self.faderText(level))."
    }

    // MARK: - Controls

    /// Move the fader. Only once the panel has been read on the current link:
    /// a change before then would start from the previous level (another
    /// unit's, after a switch).
    func setFader(_ value: Double) {
        guard value.isFinite, isConnected else { return }
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
        guard degrees.isFinite, isConnected else { return }
        knobRotation += degrees
        let next = min(max((knobValue ?? fader) + degrees / Self.degreesPerUnit,
                           Self.faderRange.lowerBound), Self.faderRange.upperBound)
        if knobValue != nil { knobValue = next }
        setFader(next)
    }

    /// One 0.1 step of the knob (arrow keys, VoiceOver, the Level menu).
    func stepKnob(up: Bool) { turnKnob(byDegrees: (up ? 0.1 : -0.1) * Self.degreesPerUnit) }

    /// The Dolby reference level, fader 7.0.
    static let referenceLevel = 7.0

    /// Put the fader on the reference level (the Level menu).
    func setReference() { setFader(Self.referenceLevel) }

    /// A front-panel button: the CP650's format buttons (`format_button`), or
    /// the CP750's input buttons (`cp750.sys.input_mode`).
    func pressButton(_ button: Int) {
        guard let cp = processor, isConnected else { return }
        // A key the front does not have selects nothing: CP750 inputs 1 to 7,
        // CP650 formats 1 to 8.
        let keys = processorModel.panel.inputs?.count ?? RemoteModel.buttonSilkscreen.count
        guard (1...keys).contains(button) else { return }
        formatButton = button
        if let inputs = processorModel.panel.inputs {
            let value = inputs[button - 1]
            send(Self.inputParam, on: cp) { await cp.set(Self.inputParam, value) }
        } else {
            // The panel counts the buttons 1 to 8; the CP650 counts them 0 to 7.
            send(Self.formatButtonParam, on: cp) { await cp.set(Self.formatButtonParam, button - 1) }
        }
    }

    func toggleMute() {
        guard let cp = processor, isConnected else { return }
        muted.toggle()
        let param = processorModel.panel.mute
        let value = muted ? 1 : 0
        send(param, on: cp) { await cp.set(param, value) }
    }

    static func faderText(_ value: Double) -> String { String(format: "%.1f", value) }

    /// The fader scale of the Dolby processors: 0.0 to 4.0 in steps of 20 dB
    /// from -90 to -10 dB, then 3 1/3 dB per unit up to +10 dB at 10;
    /// 7.0 is 0 dB (the CP650 and CP750 manuals, read from public copies).
    static func decibels(forFader fader: Double) -> Double {
        fader < 4 ? -90 + 20 * fader : (fader - 7) * 10 / 3
    }

    /// The level as shown: the fader number, or decibels with a sign.
    static func levelText(_ fader: Double, decibels: Bool) -> String {
        guard decibels else { return faderText(fader) }
        let value = (Self.decibels(forFader: fader) * 10).rounded() / 10
        return value == 0 ? "0.0" : String(format: "%+.1f", value)
    }

    var levelText: String { Self.levelText(fader, decibels: levelInDecibels) }

    /// The level with its unit, for the screens.
    var levelTextWithUnit: String { levelInDecibels ? levelText + " dB" : levelText }

    func toggleLevelUnit() {
        levelInDecibels.toggle()
        defaults.set(levelInDecibels, forKey: Self.decibelsKey)
    }

    /// Select a macro of the processor (CP850 / CP950 / CP950A).
    func selectMacro(_ number: Int) {
        guard let cp = processor, isConnected, let nameParam = processorModel.panel.macroName else { return }
        macroPreset = number
        // The new macro's name from the list; unknown, it is blank until the
        // poll reads it (the poll asks whenever the name shown is not the
        // selected macro's: `macroNameNumber`).
        macroName = macros?.first(where: { $0.number == number })?.name
        macroNameNumber = macroName == nil ? nil : number
        localChange[nameParam] = .now
        send(Self.macroPresetParam, on: cp) { await cp.set(Self.macroPresetParam, number) }
    }

    /// The next (or previous) macro in the processor's list, wrapping round.
    func stepMacro(by delta: Int) {
        guard let macros, !macros.isEmpty else { return }
        let index = macros.firstIndex { $0.number == macroPreset } ?? (delta > 0 ? -1 : 0)
        selectMacro(macros[(index + delta + macros.count) % macros.count].number)
    }

    /// The name shown for a choice in Setup.
    static func choiceName(_ model: ProcessorModel) -> String {
        model == .cp950 ? "CP950 / CP950A" : model.rawValue
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

    // MARK: - Sending

    /// Send one control change, marking the control as changed here and as
    /// being sent until the send is through, so a poll reply from before it
    /// does not overwrite it.
    private func send(_ param: String, on cp: ProcessorLink, _ operation: @escaping @Sendable () async -> Bool) {
        localChange[param] = .now
        sending[param, default: 0] += 1
        Task {
            let ok = await operation()
            sending[param, default: 1] -= 1
            if sending[param] == 0 { sending[param] = nil }
            if !ok, processor === cp { note("\(param) not sent: \(await cp.lastError)") }
        }
    }

    /// Send the latest fader value, one send at a time, so a knob turn sends
    /// only the newest level rather than every step.
    private func pumpFader() {
        guard isConnected else {
            pendingFader = nil          // the panel is unread: never send a level from before
            return
        }
        guard !faderInFlight, let value = pendingFader, let cp = processor else { return }
        pendingFader = nil
        faderInFlight = true
        let param = processorModel.panel.fader
        Task {
            if !(await cp.set(param, value)), processor === cp {
                note("\(param) not sent: \(await cp.lastError)")
            }
            faderInFlight = false
            pumpFader()
        }
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

    /// The CP650 takes one connection: after closing a link, give it this
    /// long to drop the old session before the next one opens.
    static let cp650ReopenPause = 2.0

    /// When this app last closed a CP650 session to each address and port:
    /// the main link, a Test link. Shared by every model object of the app.
    private static var cp650Closes: [String: Monotonic.Instant] = [:]

    /// Note that a session to `address` was just closed (CP650 only).
    private static func closed(_ address: String, _ port: UInt16, model: ProcessorModel) {
        if model == .cp650 { cp650Closes["\(address):\(port)"] = .now }
    }

    /// Wait out what is left of the CP650's reopen pause since this app last
    /// closed a session to `address`.
    private func pauseAfterClose(_ address: String, _ port: UInt16, model: ProcessorModel) async {
        guard model == .cp650, let closed = Self.cp650Closes["\(address):\(port)"] else { return }
        let left = (closed + reopenPause) - Monotonic.Instant.now
        await Monotonic.sleep(for: left)
    }

    private func connectNow() async {
        await disconnectNow()
        let address = trimmedHost
        guard !address.isEmpty else {
            showSetup = true
            return
        }
        let cp = ProcessorLink(host: address, port: port, model: processorModel)
        note("connect to \(address):\(cp.port) as \(processorModel.rawValue)")
        processor = cp
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
        await pauseAfterClose(address, cp.port, model: processorModel)
        guard processor === cp else { return }
        linkOpened = await cp.connect()
        guard processor === cp else { return }
        if !linkOpened { note("no answer from \(address) at connect (\(await cp.lastError)): the poll retries") }
        startPolling(cp)
    }

    private func reconnectNow() async {
        guard let cp = processor, processorHost == trimmedHost, cp.model == processorModel else {
            return await connectNow()
        }
        note("reconnect requested")
        markUnread("reconnect requested")
        formatListDue = true
        resetMacroReads()
        linkOpened = await cp.reconnect()
        guard processor === cp else { return }
        if !linkOpened { note("reconnect failed: \(await cp.lastError)") }
    }

    private func disconnectNow() async {
        pollTask?.cancel()
        pollTask = nil
        pendingFader = nil
        endKnobTurn()
        guard let cp = processor else { return }
        note("disconnect requested")
        let closedHost = processorHost
        processor = nil
        processorHost = nil
        programmedFormats = nil
        macroName = nil
        macroNameNumber = nil
        macroPreset = nil
        macros = nil
        panelRead = false
        announceConnectionChange()
        await cp.disconnect()
        if let closedHost { Self.closed(closedHost, cp.port, model: cp.model) }
    }

    /// Disable the controls until the panel has been read again on the
    /// current link, end a knob turn, and tell VoiceOver.
    private func markUnread(_ why: String) {
        endKnobTurn()
        guard panelRead else { return }
        panelRead = false
        note("controls disabled: \(why)")
        announceConnectionChange()
    }

    private func announceConnectionChange() {
        guard isConnected != announcedConnected else { return }
        announcedConnected = isConnected
        let text = isConnected ? "Processor connected" : "Processor not answering; controls disabled"
        NSAccessibility.post(
            element: NSApp,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    // MARK: - Polling

    private func startPolling(_ cp: ProcessorLink) {
        pollTask = Task { [weak self] in
            // Read at once, then every two seconds; connect() does not wait
            // for it, so a link that never answers still shows its state.
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollCycle(cp)
                await Monotonic.sleep(for: Self.pollInterval)
            }
        }
    }

    private func isCurrent(_ cp: ProcessorLink) -> Bool { processor === cp && !Task.isCancelled }

    private func pollCycle(_ cp: ProcessorLink) async {
        guard isCurrent(cp) else { return }
        if !linkOpened {
            // A processor that was off, booting or unreachable at connect
            // time is found when it comes up. Once opened, the library
            // re-opens a dropped link itself inside the next read.
            let ok = await cp.connect()
            guard isCurrent(cp) else { return }
            note("connect \(ok ? "succeeded" : "failed")")
            guard ok else { return }
            linkOpened = true
            formatListDue = true
            resetMacroReads()
        }
        await refresh(cp)
    }

    /// A new or reopened link: the macro number and name are read again,
    /// whatever went unanswered on the old one.
    private func resetMacroReads() {
        macroMisses = 0
        macroPollsToSkip = 0
    }

    /// One macro read went unanswered.
    private func macroReadMissed() {
        macroMisses += 1
        guard macroMisses >= Self.macroMissLimit else { return }
        note("macro reads unanswered: paused for \(Self.macroPausePolls) polls")
        macroMisses = 0
        macroPollsToSkip = Self.macroPausePolls
    }

    /// A reply to a read that started at `start` may update the panel only
    /// if no send of that control is under way, and the control was not
    /// changed here since just before the read.
    private func mayApply(_ param: String, readStartedAt start: Monotonic.Instant) -> Bool {
        if sending[param] != nil { return false }
        if let changed = localChange[param], changed > start - Self.pollHoldOff { return false }
        return true
    }

    private func refresh(_ cp: ProcessorLink) async {
        let panel = processorModel.panel
        var start = Monotonic.Instant.now
        let faderReply = await cp.get(panel.fader)
        guard isCurrent(cp) else { return }
        guard let faderReply else {
            // Unanswered: after a few in a row, reopen a link that is open
            // but hung, and skip the other reads (each would time out too).
            silentPolls += 1
            note("fader read unanswered (\(silentPolls) of \(Self.silentPollLimit)): \(await cp.lastError)")
            markUnread("fader read unanswered")
            if silentPolls >= Self.silentPollLimit {
                note("reopening the link: \(Self.silentPollLimit) fader reads unanswered")
                silentPolls = 0
                formatListDue = true
                resetMacroReads()
                linkReopens += 1
                _ = await cp.reconnect()
            }
            return
        }
        silentPolls = 0
        let faderRead = Self.faderLevel(faderReply)
        if let level = faderRead, mayApply(panel.fader, readStartedAt: start),
           !isTurningKnob, faderIsSettled, fader != level {
            fader = level
        }

        // The selected button: the CP650's format button, or the CP750's input.
        start = .now
        if processorModel == .cp650 {
            if let reply = await cp.get(Self.formatButtonParam), isCurrent(cp),
               let wireValue = Int(reply), (0...7).contains(wireValue),
               mayApply(Self.formatButtonParam, readStartedAt: start),
               formatButton != wireValue + 1 {
                formatButton = wireValue + 1
            }
        } else if let inputs = panel.inputs, let reply = await cp.get(Self.inputParam), isCurrent(cp),
                  let index = inputs.firstIndex(of: reply),
                  mayApply(Self.inputParam, readStartedAt: start),
                  formatButton != index + 1 {
            formatButton = index + 1
        }

        start = .now
        let muteReply = await cp.get(panel.mute)
        guard isCurrent(cp) else { return }
        if let muteReply, mayApply(panel.mute, readStartedAt: start), muted != (muteReply == "1") {
            muted = muteReply == "1"
        }
        // The controls come on only once this pass has read the fader and
        // the mute: enabled earlier, they showed the previous state, and a
        // Mute pressed then sent the opposite of what was meant.
        if faderRead != nil, muteReply != nil, !panelRead {
            panelRead = true
            note("panel read: controls enabled")
            announceConnectionChange()
        }

        // The selected macro, for the screen: its number every poll, its name
        // whenever the name shown is not that macro's. Unanswered reads pause
        // these reads for a few polls (`macroReadMissed`).
        if panel.macroName != nil, macroPollsToSkip > 0 { macroPollsToSkip -= 1 }
        if let nameParam = panel.macroName, macroPollsToSkip == 0 {
            start = .now
            let presetReply = await cp.get(Self.macroPresetParam)
            guard isCurrent(cp) else { return }
            if let presetReply {
                macroMisses = 0
                if let number = Int(presetReply.trimmingCharacters(in: .whitespaces)),
                   mayApply(Self.macroPresetParam, readStartedAt: start) {
                    if macroNameNumber == number {
                        macroPreset = number
                    } else {
                        // The number and its name change together: a new key
                        // is never shown beside the old macro's name.
                        start = .now
                        let nameReply = await cp.get(nameParam)
                        guard isCurrent(cp) else { return }
                        if let nameReply {
                            if mayApply(nameParam, readStartedAt: start),
                               mayApply(Self.macroPresetParam, readStartedAt: start) {
                                macroPreset = number
                                macroName = nameReply.trimmingCharacters(in: .whitespaces)
                                macroNameNumber = number
                            }
                        } else {
                            macroReadMissed()
                            macroPreset = number          // the number without a name, not the old name
                            macroName = macros?.first { $0.number == number }?.name
                            macroNameNumber = macroName == nil ? nil : number
                        }
                    }
                }
            } else {
                macroReadMissed()
            }
        }

        // The CP650's programmed formats change only in setup: one attempt
        // per opened link, so a processor that never answers it is not asked
        // again.
        guard processorModel == .cp650, formatListDue, isCurrent(cp) else { return }
        formatListDue = false
        if let reply = await cp.get("format_list"), isCurrent(cp) {
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
        case .cp850: 483 / 89          // a 2U, 19-inch front
        case .cp950, .cp950a: 890 / 242
        }
    }
}

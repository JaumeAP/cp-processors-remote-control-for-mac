// The app's live state: one link to the processor at the configured address
// (`ProcessorLink`, over the released cpseries library), the fader level, the
// selected front-panel button, the mute flag and the macro. The connection
// lives in RemoteModel+Connection.swift, the reads of the panel in
// RemoteModel+Polling.swift and the value conversions in RemoteModel+Values.swift.

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
    var macroName: String?
}

extension ProcessorModel {
    var panel: PanelProfile {
        switch self {
        case .cp650:
            PanelProfile(fader: "fader_level", mute: "mute", inputs: nil, faderMinimum: 0)
        case .cp750:
            PanelProfile(
                fader: "cp750.sys.fader", mute: "cp750.sys.mute",
                inputs: ["dig_1", "dig_2", "dig_3", "dig_4", "analog", "non_sync", "mic"],
                faderMinimum: 0)
        case .cp850, .cp950, .cp950a:
            PanelProfile(
                fader: "sys.fader", mute: "sys.mute", inputs: nil, faderMinimum: 1,
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
    static let pollHoldOff: TimeInterval = 1.5
    /// Unanswered fader reads in a row after which the link is closed and
    /// opened again (a hung control session).
    static let silentPollLimit = 2
    /// Seconds between two reads of the panel.
    static let pollInterval: TimeInterval = 2
    static let hostKey = "processorHost"
    static let modelKey = "processorModel"
    static let decibelsKey = "levelInDecibels"
    /// The models the Setup menu offers. The CP950 choice covers the CP950A
    /// (one front, one protocol).
    static let choices: [ProcessorModel] = [.cp650, .cp750, .cp850, .cp950]
    /// Unanswered macro reads in a row; at `macroMissLimit` the macro reads
    /// pause for `macroPausePolls` polls (each miss costs a read timeout),
    /// then are tried again. Any answered macro read clears it.
    static let macroMissLimit = 2
    static let macroPausePolls = 5
    static let macroPresetParam = "sys.macro_preset"
    static let inputParam = "cp750.sys.input_mode"
    static let formatButtonParam = "format_button"
    /// The Dolby reference level, fader 7.0.
    static let referenceLevel = 7.0
    /// The CP650 takes one connection: after closing a link, give it this
    /// long to drop the old session before the next one opens.
    static let cp650ReopenPause = 2.0
    /// When this app last closed a CP650 session to each address and port:
    /// the main link, a Test link. Shared by every model object of the app.
    static var cp650Closes: [String: Monotonic.Instant] = [:]

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
    @Published var processorModel: ProcessorModel
    @Published var fader: Double = 7.0
    @Published var formatButton: Int?
    /// The format number programmed on each button, from the processor's
    /// `format_list`; nil until it reports eight entries.
    @Published var programmedFormats: [String]?
    /// The selected macro's name, read from the processor (CP850 / CP950 / CP950A).
    @Published var macroName: String?
    @Published var macroPreset: Int?
    /// The macros the processor offers, in its order (CP850 / CP950 / CP950A).
    /// Not read in this build: the list is a multi-line reply, which the
    /// cpseries library does not return.
    @Published var macros: [Macro]?
    var macroMisses = 0
    var macroPollsToSkip = 0
    /// The macro number `macroName` belongs to; nil when no name is known.
    var macroNameNumber: Int?

    struct Macro: Equatable, Sendable {
        let number: Int
        let name: String
    }

    /// Show the level in decibels (7.0 is 0 dB) instead of the fader number.
    @Published var levelInDecibels = false
    @Published var muted = false
    /// The fader and the mute have been read on the current link. Until then
    /// the controls stay disabled, so a first touch never starts from a stale
    /// level.
    @Published var panelRead = false
    /// The knob's drawn rotation, in degrees, free of the fader's limits.
    @Published var knobRotation: Double = 0

    /// The unrounded fader value during a turn, so slow turns add up.
    var knobValue: Double?
    var isTurningKnob: Bool { knobValue != nil }

    var processor: ProcessorLink?
    /// The address `processor` was built for.
    var processorHost: String?
    /// The link has been opened once; until then each poll tries to open it.
    var linkOpened = false
    var pollTask: Task<Void, Never>?
    /// The tail of the connect/reconnect/disconnect chain: each waits for the
    /// one before, so two of them never interleave.
    var lifecycle: Task<Void, Never>?
    var pendingFader: Int?
    var faderInFlight = false
    /// When each control was last changed here.
    var localChange: [String: Monotonic.Instant] = [:]
    /// Sends of each control not yet through.
    var sending: [String: Int] = [:]
    /// `format_list` is read once per opened link.
    var formatListDue = true
    var silentPolls = 0
    var announcedConnected = false

    /// Where the IP address is kept, and the TCP port (nil: the model's own).
    /// Both are injectable so tests use their own and a simulator.
    let defaults: UserDefaults
    let port: UInt16?

    /// Where the app writes its events; nil for none (tests).
    let log: ConnectionLog?

    /// The CP650's reopen pause, `cp650ReopenPause` unless a test sets it.
    let reopenPause: Double

    init(
        defaults: UserDefaults = .standard, port: UInt16? = nil, log: ConnectionLog? = .shared,
        reopenPause: Double = RemoteModel.cp650ReopenPause
    ) {
        self.defaults = defaults
        self.port = port
        self.log = log
        self.reopenPause = reopenPause
        host = defaults.string(forKey: Self.hostKey) ?? ""
        levelInDecibels = defaults.bool(forKey: Self.decibelsKey)
        processorModel =
            defaults.string(forKey: Self.modelKey)
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

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

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
        let next = min(
            max(
                (knobValue ?? fader) + degrees / Self.degreesPerUnit,
                Self.faderRange.lowerBound), Self.faderRange.upperBound)
        if knobValue != nil { knobValue = next }
        setFader(next)
    }

    /// One 0.1 step of the knob (arrow keys, VoiceOver, the Level menu).
    func stepKnob(up upward: Bool) { turnKnob(byDegrees: (upward ? 0.1 : -0.1) * Self.degreesPerUnit) }

    /// Put the fader on the reference level (the Level menu).
    func setReference() { setFader(Self.referenceLevel) }

    /// A front-panel button: the CP650's format buttons (`format_button`), or
    /// the CP750's input buttons (`cp750.sys.input_mode`).
    func pressButton(_ button: Int) {
        guard let link = processor, isConnected else { return }
        // A key the front does not have selects nothing: CP750 inputs 1 to 7,
        // CP650 formats 1 to 8.
        let keys = processorModel.panel.inputs?.count ?? RemoteModel.buttonSilkscreen.count
        guard (1...keys).contains(button) else { return }
        formatButton = button
        if let inputs = processorModel.panel.inputs {
            let value = inputs[button - 1]
            send(Self.inputParam, on: link) { await link.set(Self.inputParam, value) }
        } else {
            // The panel counts the buttons 1 to 8; the CP650 counts them 0 to 7.
            send(Self.formatButtonParam, on: link) { await link.set(Self.formatButtonParam, button - 1) }
        }
    }

    func toggleMute() {
        guard let link = processor, isConnected else { return }
        muted.toggle()
        let param = processorModel.panel.mute
        let value = muted ? 1 : 0
        send(param, on: link) { await link.set(param, value) }
    }

    func toggleLevelUnit() {
        levelInDecibels.toggle()
        defaults.set(levelInDecibels, forKey: Self.decibelsKey)
    }

    /// Select a macro of the processor (CP850 / CP950 / CP950A).
    func selectMacro(_ number: Int) {
        guard let link = processor, isConnected, let nameParam = processorModel.panel.macroName else { return }
        macroPreset = number
        // The new macro's name from the list; unknown, it is blank until the
        // poll reads it (the poll asks whenever the name shown is not the
        // selected macro's: `macroNameNumber`).
        macroName = macros?.first(where: { $0.number == number })?.name
        macroNameNumber = macroName == nil ? nil : number
        localChange[nameParam] = .now
        send(Self.macroPresetParam, on: link) { await link.set(Self.macroPresetParam, number) }
    }

    /// The next (or previous) macro in the processor's list, wrapping round.
    func stepMacro(by delta: Int) {
        guard let macros, !macros.isEmpty else { return }
        let index = macros.firstIndex { $0.number == macroPreset } ?? (delta > 0 ? -1 : 0)
        selectMacro(macros[(index + delta + macros.count) % macros.count].number)
    }

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

    /// The level with its unit, for the screens.
    var levelTextWithUnit: String { levelInDecibels ? levelText + " dB" : levelText }

    var levelText: String { Self.levelText(fader, decibels: levelInDecibels) }

    /// One line in the connection log.
    func note(_ text: String) {
        log?.write("app: \(text)")
    }
}

extension ProcessorModel {
    /// Width over height of the front panel, as the manual draws it.
    var aspect: CGFloat {
        switch self {
        case .cp650: panelAspect
        case .cp750: 935 / 180
        case .cp850: 483 / 89  // a 2U, 19-inch front
        case .cp950, .cp950a: 890 / 242
        }
    }
}

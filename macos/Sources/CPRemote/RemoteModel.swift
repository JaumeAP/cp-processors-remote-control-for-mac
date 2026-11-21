// The app's state: the configured address and processor model, the fader
// level, the selected front-panel button, the mute flag and the macros. This
// build has no processor communication: nothing connects, so the controls
// stay disabled.

import Foundation
import SwiftUI

/// What one processor model's front panel offers: its input buttons (CP750
/// only), the fader's lowest value, and whether it has macros (CP850 / CP950 /
/// CP950A).
struct PanelProfile {
    /// Input selection: one entry per front button, in button order (CP750
    /// only).
    let inputs: [String]?
    /// Lowest value the fader takes, in tenths (CP950: 1 to 100).
    let faderMinimum: Int
    /// The panel shows the selected macro's name (CP850 / CP950 / CP950A).
    var macroName: String? = nil
}

extension ProcessorModel {
    var panel: PanelProfile {
        switch self {
        case .cp650:
            PanelProfile(inputs: nil, faderMinimum: 0)
        case .cp750:
            PanelProfile(inputs: ["dig_1", "dig_2", "dig_3", "dig_4", "analog", "non_sync", "mic"],
                         faderMinimum: 0)
        case .cp850, .cp950, .cp950a:
            PanelProfile(inputs: nil, faderMinimum: 1, macroName: "sys.macro_name")
        }
    }
}

@MainActor
final class RemoteModel: ObservableObject {
    /// The generic silkscreen on the eight format buttons (CP650 user's
    /// manual, figure 2-1); fixed, whatever formats are programmed.
    static let buttonSilkscreen = ["01", "04", "05", "10", "11", "U1", "U2", "NS"]
    /// The fader runs 0.0 to 10.0.
    static let faderRange: ClosedRange<Double> = 0...10
    /// The knob is an endless encoder: three full turns run the fader from
    /// 0.0 to 10.0, so one degree is 1/108 of a unit. It has no end stops:
    /// past 0.0 or 10.0 it keeps turning and the fader stays at the limit.
    static let degreesPerUnit = 3 * 360 / (faderRange.upperBound - faderRange.lowerBound)
    private static let hostKey = "processorHost"
    private static let modelKey = "processorModel"
    /// The models the Setup menu offers. The CP950 choice covers the CP950A
    /// (one front).
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

    /// The processor model: its front panel and its controls.
    @Published private(set) var processorModel: ProcessorModel
    @Published private(set) var fader: Double = 7.0
    @Published private(set) var formatButton: Int?
    /// The format number programmed on each button; nil until known.
    @Published private(set) var programmedFormats: [String]?
    /// The selected macro's name (CP850 / CP950 / CP950A).
    @Published private(set) var macroName: String?
    @Published private(set) var macroPreset: Int?
    /// The macros the processor offers, in its order (CP850 / CP950 / CP950A).
    @Published private(set) var macros: [Macro]?

    struct Macro: Equatable, Sendable {
        let number: Int
        let name: String
    }

    /// Show the level in decibels (7.0 is 0 dB) instead of the fader number.
    @Published private(set) var levelInDecibels = false
    private static let decibelsKey = "levelInDecibels"
    @Published private(set) var muted = false
    /// The knob's drawn rotation, in degrees, free of the fader's limits.
    @Published private(set) var knobRotation: Double = 0

    /// The unrounded fader value during a turn, so slow turns add up.
    private var knobValue: Double?
    var isTurningKnob: Bool { knobValue != nil }

    /// Where the IP address is kept. Injectable so tests use their own.
    private let defaults: UserDefaults

    /// Where the app writes its events; nil for none (tests).
    private let log: ConnectionLog?

    init(defaults: UserDefaults = .standard, log: ConnectionLog? = .shared) {
        self.defaults = defaults
        self.log = log
        host = defaults.string(forKey: Self.hostKey) ?? ""
        levelInDecibels = defaults.bool(forKey: Self.decibelsKey)
        processorModel = defaults.string(forKey: Self.modelKey)
            .flatMap { ProcessorModel(rawValue: $0) } ?? .cp650
    }

    /// Choose the processor model and remember it.
    func choose(_ model: ProcessorModel) {
        processorModel = model
        defaults.set(model.rawValue, forKey: Self.modelKey)
    }

    /// The controls work only on a connected processor. This build has no
    /// processor communication, so it is never connected.
    var isConnected: Bool { false }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Connection

    /// With no address saved, open Setup. Otherwise nothing connects: this
    /// build has no processor communication.
    func connect() async {
        guard !trimmedHost.isEmpty else {
            showSetup = true
            return
        }
        note("connect to \(trimmedHost) as \(processorModel.rawValue): no processor communication in this build")
    }

    func reconnect() async { await connect() }

    func disconnect() async { endKnobTurn() }

    /// The Setup sheet's Test button. This build has no processor
    /// communication, so it only says so.
    func test(address raw: String, model chosen: ProcessorModel? = nil) async -> String {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return "Type an IP address first." }
        let name = Self.choiceName(chosen ?? processorModel)
        return "Not tested: this version of CP Remote does not communicate with the \(name)."
    }

    // MARK: - Controls

    /// Move the fader. Only on a connected processor.
    func setFader(_ value: Double) {
        guard value.isFinite, isConnected else { return }
        let clamped = Self.clampFader(value)
        let tenths = max(Int((clamped * 10).rounded()), processorModel.panel.faderMinimum)
        fader = Double(tenths) / 10
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

    /// A front-panel button: the CP650's format buttons, or the CP750's input
    /// buttons.
    func pressButton(_ button: Int) {
        guard isConnected else { return }
        // A key the front does not have selects nothing: CP750 inputs 1 to 7,
        // CP650 formats 1 to 8.
        let keys = processorModel.panel.inputs?.count ?? RemoteModel.buttonSilkscreen.count
        guard (1...keys).contains(button) else { return }
        formatButton = button
    }

    func toggleMute() {
        guard isConnected else { return }
        muted.toggle()
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
        guard isConnected, processorModel.panel.macroName != nil else { return }
        macroPreset = number
        macroName = macros?.first(where: { $0.number == number })?.name
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

    /// One line in the connection log.
    private func note(_ text: String) {
        log?.write("app: \(text)")
    }

    // MARK: - Values

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

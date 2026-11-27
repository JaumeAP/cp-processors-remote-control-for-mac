// A sweep of every control of the app against the processor simulator, with
// the simulator's own control channel (`--control`) as the ground truth. Each
// test starts a simulator of one model, connects the app to it, drives the
// controls and, after every step, checks that the simulator and the app agree.
// The CP650's simulator also takes front-panel changes (`panel KEY VALUE`),
// which it pushes to the app as the unit does; the other models have no such
// push, so the app reads their changes on its poll. Runs only when CPSIM_BIN
// names a processor_sim binary.

import Foundation
import Testing

@testable import CPRemote

private let simulatorBinary: String? = {
    guard let path = ProcessInfo.processInfo.environment["CPSIM_BIN"], !path.isEmpty else { return nil }
    return path
}()

/// Decode the simulator's hex fields (`STATE <name> <value> <kind>`).
private func decodeHex(_ hex: String) -> String? {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// A processor simulator running with `--control`. Its replies are read on a
/// background thread; `send` waits for the reply's last line.
private final class SimulatorProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()
    private var lines: [String] = []
    private var partial = ""
    private var consumed = 0

    init(model: String, port: UInt16) throws {
        process.executableURL = URL(fileURLWithPath: simulatorBinary ?? "")
        process.arguments = ["--model", model, "--port", "\(port)", "--control"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        try process.run()
    }

    deinit { stop() }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        condition.lock()
        var parts = (partial + String(decoding: data, as: UTF8.self)).components(separatedBy: "\n")
        partial = parts.removeLast()
        lines += parts
        condition.broadcast()
        condition.unlock()
    }

    /// Send one command and return its reply, up to the line `END` or `OK`
    /// (or an `ERR` line). Nil when no such line comes within `timeout`.
    func send(_ command: String, timeout: Double = 5) -> [String]? {
        input.fileHandleForWriting.write(Data((command + "\n").utf8))
        let end = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            let stop = lines[consumed...].firstIndex { $0 == "END" || $0 == "OK" || $0.hasPrefix("ERR") }
            if let stop {
                let reply = Array(lines[consumed...stop])
                consumed = stop + 1
                return reply
            }
            if !condition.wait(until: end) { return nil }
        }
    }

    /// Every parameter the simulator holds, by name, with its value as text.
    func state() -> [String: String]? {
        guard let reply = send("state") else { return nil }
        var values: [String: String] = [:]
        for line in reply where line.hasPrefix("STATE ") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, let name = decodeHex(String(parts[1])),
                let value = decodeHex(String(parts[2]))
            else { continue }
            values[name] = value
        }
        return values
    }

    /// A front-panel change, as the CP650's keys and fader make it.
    func panel(_ key: String, _ value: String) -> Bool {
        send("panel \(key) \(value)")?.contains("OK") ?? false
    }
}

/// Wait until `condition` holds, at most `seconds`.
@MainActor
private func settle(_ seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
    let end = Monotonic.Instant.now + seconds
    while Monotonic.Instant.now < end {
        if condition() { return true }
        await Monotonic.sleep(for: 0.1)
    }
    return condition()
}

/// Where the app and the simulator disagree, in words: empty when they agree.
@MainActor
private func mismatches(_ model: RemoteModel, _ sim: SimulatorProcess) -> [String] {
    guard let state = sim.state() else { return ["no state reply"] }
    let panel = model.processorModel.panel
    var problems: [String] = []
    if let level = state[panel.fader].flatMap(Double.init) {
        if abs(model.fader - level / 10) > 0.05 { problems.append("fader app \(model.fader) sim \(level / 10)") }
    } else {
        problems.append("no fader in the simulator")
    }
    if let mute = state[panel.mute], model.muted != (mute == "1") {
        problems.append("mute app \(model.muted) sim \(mute)")
    }
    if model.processorModel == .cp650 {
        if let raw = state[RemoteModel.formatButtonParam].flatMap(Int.init), model.formatButton != raw + 1 {
            problems.append("format app \(String(describing: model.formatButton)) sim \(raw)")
        }
    } else if let inputs = panel.inputs {
        if let name = state[RemoteModel.inputParam], model.formatButton != inputs.firstIndex(of: name).map({ $0 + 1 }) {
            problems.append("input app \(String(describing: model.formatButton)) sim \(name)")
        }
    } else if panel.macroName != nil {
        if let preset = state[RemoteModel.macroPresetParam].flatMap(Int.init), model.macroPreset != preset {
            problems.append("macro app \(String(describing: model.macroPreset)) sim \(preset)")
        }
    }
    return problems
}

/// Wait until the app has sent everything and agrees with the simulator; the
/// last disagreement otherwise.
@MainActor
private func settled(_ model: RemoteModel, _ sim: SimulatorProcess) async -> [String] {
    var problems = ["not checked"]
    _ = await settle {
        problems = model.sending.isEmpty ? mismatches(model, sim) : ["sends pending"]
        return problems.isEmpty
    }
    return problems
}

/// Connect the app to a simulator of `processor` on `port`, and wait for the panel.
@MainActor
private func connect(_ processor: ProcessorModel, port: UInt16) async throws -> RemoteModel {
    let suite = "CPRemoteTests.sweep.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = RemoteModel(defaults: defaults, port: port, log: nil, reopenPause: 0.5)
    model.host = "127.0.0.1"
    model.choose(processor)
    await model.connect()
    try #require(await settle { model.isConnected }, "the panel is read and the controls come on")
    return model
}

/// A fixed sequence of numbers, so a failing run can be repeated exactly.
private struct Sequence {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
}

@MainActor
@Suite(.serialized, .enabled(if: simulatorBinary != nil))
struct SimulatorSweepTests {
    /// Every format button, the mute, the fader and the knob, then the
    /// simulator's own front-panel changes, then a random mix of both.
    @Test func cp650EveryControlAgreesWithTheSimulator() async throws {
        let sim = try SimulatorProcess(model: "CP650", port: 61650)
        defer { sim.stop() }
        let model = try await connect(.cp650, port: 61650)

        for button in 1...8 {
            model.pressButton(button)
            let problems = await settled(model, sim)
            #expect(problems.isEmpty, "format button \(button): \(problems)")
        }
        for _ in 0..<2 {
            model.toggleMute()
            let problems = await settled(model, sim)
            #expect(problems.isEmpty, "mute: \(problems)")
        }
        for level in [0.0, 0.1, 2.5, 5.5, 10.0, 7.0] {
            model.setFader(level)
            let problems = await settled(model, sim)
            #expect(problems.isEmpty, "fader \(level): \(problems)")
        }
        model.setFader(9.8)
        for _ in 0..<5 { model.stepKnob(up: true) }
        #expect(await settled(model, sim).isEmpty, "knob past 10.0 holds at 10.0")
        for _ in 0..<25 { model.stepKnob(up: false) }
        #expect(await settled(model, sim).isEmpty, "knob down 25 steps")

        #expect(sim.panel("fader_level", "33"))
        #expect(await settle { abs(model.fader - 3.3) < 0.05 }, "the simulator's fader reaches the app")
        #expect(sim.panel("mute", "1"))
        #expect(await settle { model.muted }, "the simulator's mute reaches the app")
        #expect(sim.panel("mute", "0"))
        #expect(await settle { !model.muted }, "the simulator's unmute reaches the app")
        #expect(sim.panel("format_button", "5"))
        #expect(await settle { model.formatButton == 6 }, "the simulator's format button reaches the app")
        #expect(await settled(model, sim).isEmpty, "the app and the simulator agree after the panel changes")

        var random = Sequence(state: 20_261_127)
        for step in 0..<60 {
            switch random.next(7) {
            case 0: model.pressButton(1 + random.next(8))
            case 1: model.toggleMute()
            case 2: model.setFader(Double(random.next(101)) / 10)
            case 3: model.stepKnob(up: random.next(2) == 0)
            case 4: _ = sim.panel("fader_level", String(random.next(101)))
            case 5: _ = sim.panel("mute", String(random.next(2)))
            default: _ = sim.panel("format_button", String(random.next(8)))
            }
            let problems = await settled(model, sim)
            #expect(problems.isEmpty, "random step \(step): \(problems)")
        }
    }

    /// The CP750's seven inputs, the mute, the fader and the knob, client to simulator.
    @Test func cp750EveryControlAgreesWithTheSimulator() async throws {
        let sim = try SimulatorProcess(model: "CP750", port: 61750)
        defer { sim.stop() }
        let model = try await connect(.cp750, port: 61750)
        for input in 1...7 {
            model.pressButton(input)
            let problems = await settled(model, sim)
            #expect(problems.isEmpty, "input \(input): \(problems)")
        }
        for _ in 0..<2 {
            model.toggleMute()
            #expect(await settled(model, sim).isEmpty, "mute")
        }
        for level in [0.0, 2.5, 7.0, 10.0] {
            model.setFader(level)
            let problems = await settled(model, sim)
            #expect(problems.isEmpty, "fader \(level): \(problems)")
        }
        for _ in 0..<10 { model.stepKnob(up: true) }
        #expect(await settled(model, sim).isEmpty, "knob up 10 steps")
    }

    /// The macro keys of the CP850, CP950 and CP950A, the mute and the fader, client to simulator.
    @Test(arguments: [
        (ProcessorModel.cp850, "CP850", UInt16(61850)),
        (.cp950, "CP950", UInt16(61950)),
        (.cp950a, "CP950A", UInt16(61960)),
    ])
    func macroModelEveryControlAgreesWithTheSimulator(
        _ processor: ProcessorModel, _ name: String, _ port: UInt16
    ) async throws {
        let sim = try SimulatorProcess(model: name, port: port)
        defer { sim.stop() }
        let model = try await connect(processor, port: port)
        for macro in 1...8 {
            model.selectMacro(macro)
            let problems = await settled(model, sim)
            #expect(problems.isEmpty, "macro \(macro): \(problems)")
        }
        for _ in 0..<2 {
            model.toggleMute()
            #expect(await settled(model, sim).isEmpty, "mute")
        }
        for level in [1.0, 5.5, 10.0] {
            model.setFader(level)
            let problems = await settled(model, sim)
            #expect(problems.isEmpty, "fader \(level): \(problems)")
        }
    }
}

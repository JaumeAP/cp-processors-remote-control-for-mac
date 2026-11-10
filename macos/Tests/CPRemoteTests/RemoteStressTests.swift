// Stress tests of the app's model (`RemoteModel`, the code the panel's
// buttons and knob call) against the C++ simulator: storms of knob turns,
// format presses and mute toggles, links dropped mid-storm, the simulator
// killed and restarted, connect/disconnect cycles, and a processor that
// accepts the link but never answers. After each storm the processor must
// hold exactly the value the panel shows.

import AppKit
import CPx50Comms
import Foundation
import SwiftUI
import Testing
@testable import CPRemote

// MARK: - Simulator

/// `$CPSIM_BIN`, else `cpp/build/processor_sim` in this checkout.
private let simulatorPath: String? = {
    if let env = ProcessInfo.processInfo.environment["CPSIM_BIN"], !env.isEmpty {
        return FileManager.default.isExecutableFile(atPath: env) ? env : nil
    }
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let path = repo.appendingPathComponent("cpp/build/processor_sim").path
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
}()

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// One `processor_sim --model CP650 --profile --log` on loopback.
private final class Simulator: @unchecked Sendable {
    let process = Process()
    let port: UInt16
    private let log = Locked(Data())

    private let input = Pipe()
    private let replies = Locked(Data())

    /// With `control`, the simulator also reads `--control` commands (see
    /// `command(_:)`).
    let model: ProcessorModel

    init(model: ProcessorModel = .cp650, port requested: UInt16 = 0, control: Bool = false,
         extraArguments: [String] = []) async throws {
        self.model = model
        let path = try #require(simulatorPath)
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--model", model.rawValue, "--host", "127.0.0.1", "--port", String(requested),
                             "--profile", "--log"] + (control ? ["--control"] : []) + extraArguments
        process.standardInput = input
        let out = Pipe()
        process.standardOutput = out
        let err = Pipe()
        process.standardError = err
        err.fileHandleForReading.readabilityHandler = { [log] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            log.withLock { $0.append(chunk) }
        }
        try process.run()
        var found: UInt16?
        for try await line in out.fileHandleForReading.bytes.lines {
            if let colon = line.lastIndex(of: ":"),
               let p = UInt16(line[line.index(after: colon)...].prefix { $0.isNumber }) {
                found = p
            }
            break
        }
        port = try #require(found)
        out.fileHandleForReading.readabilityHandler = { [replies] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            replies.withLock { $0.append(chunk) }
        }
    }

    /// Send one `--control` command; its reply (through `OK`, `END` or `ERR`).
    func command(_ line: String) async -> String {
        replies.withLock { $0.removeAll() }
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let text = replies.withLock { String(decoding: $0, as: UTF8.self) }
            if text.hasSuffix("OK\n") || text.hasSuffix("END\n") || text.hasSuffix("ERR\n") { return text }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return ""
    }

    /// Live TCP control links, from `--control`'s `connections`.
    func connections() async -> Int? {
        let reply = await command("connections")
        return reply.split(separator: "\n").first.flatMap { Int($0.dropFirst("COUNT ".count)) }
    }

    /// SIGINT, at most 5 s, then SIGKILL (never `waitUntilExit()`).
    func stop() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.interrupt()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { kill(pid, SIGKILL) }
    }

    /// Close every live TCP link; the simulator keeps listening.
    func dropConnections() { kill(process.processIdentifier, SIGUSR1) }

    func tail(_ n: Int) -> String {
        let text = log.withLock { String(decoding: $0, as: UTF8.self) }
        return text.split(separator: "\n").suffix(n).joined(separator: "\n")
    }

    /// SET lines the simulator received for `param`.
    func setsReceived(_ param: String) -> Int {
        let text = log.withLock { String(decoding: $0, as: UTF8.self) }
        return text.split(separator: "\n").filter { $0.contains("recv: \(param)=") }.count
    }

    deinit { stop() }
}

// MARK: - Helpers

/// A model on its own defaults suite, pointed at the simulator, with the
/// simulator's processor model chosen.
@MainActor
private func makeModel(_ sim: Simulator) -> RemoteModel {
    // One suite for every test, emptied each time: no file per model.
    let suite = "CPRemoteTests"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let model = RemoteModel(defaults: defaults, port: sim.port, log: nil)
    model.host = "127.0.0.1"
    model.choose(sim.model)
    return model
}

/// Read `param` on the simulator through a separate link.
private func probe(_ sim: Simulator, _ param: String) async -> String? {
    let cp = DolbyCP(host: "127.0.0.1", port: sim.port, model: sim.model, gap: 0.05)
    guard await cp.connect() else { return nil }
    let value = try? await cp.get(param, timeout: 1)
    await cp.disconnect()
    return value.flatMap { $0 }
}

/// Poll `condition` every 50 ms for up to `seconds`.
@MainActor
private func eventually(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

/// The fader as the wire carries it: tenths, `7.0` is `"70"`.
private func wire(_ fader: Double) -> String { String(Int((fader * 10).rounded())) }

/// A seeded generator, so a failing storm repeats exactly.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Connect and wait until the first read has filled the panel.
@MainActor
private func connected(_ sim: Simulator) async throws -> RemoteModel {
    let model = makeModel(sim)
    await model.connect()
    #expect(await eventually { model.isConnected && model.formatButton != nil && model.programmedFormats != nil })
    return model
}

/// Wait for the knob's SETs to drain and the processor to hold `expected`.
@MainActor
private func settles(_ model: RemoteModel, _ sim: Simulator, on expected: String) async -> Bool {
    await eventually(20) {
        guard model.faderIsSettled else { return false }
        return await probe(sim, model.processorModel.panel.fader) == expected
    }
}

// MARK: - Tests

@MainActor
@Suite(.serialized, .enabled(if: simulatorPath != nil, "needs cpp/build/processor_sim or $CPSIM_BIN"))
struct RemoteStressTests {
    /// Values unlike the model's defaults, so a read is told from no read.
    @Test func connectReadsThePanel() async throws {
        let sim = try await Simulator(extraArguments: ["--seed", "fader_level=45", "--seed", "format_button=3",
                                                       "--seed", "mute=1"])
        defer { sim.stop() }
        let model = try await connected(sim)
        #expect(model.fader == 4.5)
        #expect(model.formatButton == 4)   // the CP650 counts its buttons from 0
        #expect(model.muted == true)
        #expect(model.programmedFormats == ["01", "04", "05", "10", "93", "94", "95", "99"])
        #expect(model.currentFormat == "10")
        await model.disconnect()
    }

    /// Three full turns run 0.0 to 10.0; the knob has no end stops.
    @Test func threeTurnsSpanTheRangeInOneDegreeSteps() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let model = try await connected(sim)
        model.setFader(0)
        #expect(await settles(model, sim, on: "0"))

        model.beginKnobTurn()
        for _ in 0..<1080 { model.turnKnob(byDegrees: 1) }
        model.endKnobTurn()
        #expect(model.fader == 10.0)
        #expect(await settles(model, sim, on: "100"))

        // Two more turns past the top: the knob keeps turning, the fader holds.
        model.beginKnobTurn()
        for _ in 0..<720 { model.turnKnob(byDegrees: 1) }
        model.endKnobTurn()
        #expect(model.fader == 10.0)
        #expect(model.knobRotation == 1800)

        // And straight back down: the first degree back already lowers it.
        model.beginKnobTurn()
        model.turnKnob(byDegrees: -10.8)
        #expect(model.fader == 9.9)
        for _ in 0..<1070 { model.turnKnob(byDegrees: -1) }
        model.endKnobTurn()
        #expect(model.fader == 0.0)
        #expect(await settles(model, sim, on: "0"))
        await model.disconnect()
    }

    /// 20 000 random turns as fast as the main actor runs them: the SETs
    /// coalesce (one in flight), and the processor ends on the shown value.
    @Test func knobStormEndsOnTheShownValue() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let model = try await connected(sim)
        var rng = SplitMix64(state: 650)
        let started = ContinuousClock.now
        model.beginKnobTurn()
        for step in 0..<20_000 {
            model.turnKnob(byDegrees: Double.random(in: -20...22, using: &rng))
            if step % 500 == 0 { await Task.yield() }
        }
        model.endKnobTurn()
        let stormTime = ContinuousClock.now - started
        let expected = wire(model.fader)
        #expect(await settles(model, sim, on: expected))
        let sets = sim.setsReceived("fader_level")
        #expect(sets >= 1)
        #expect(sets < 200, "SETs must coalesce, got \(sets)")
        print("knob storm: 20000 turns in \(stormTime), \(sets) SETs on the wire, final \(expected)")
        // A poll after the storm must not snap the panel back.
        try await Task.sleep(for: .seconds(2.5))
        #expect(wire(model.fader) == expected)
        await model.disconnect()
    }

    /// While polling runs, the panel never jumps away from what was last
    /// set here: 60 changes of each control at random moments, checked
    /// between them (a stale poll reply used to snap the knob back).
    @Test func pollingNeverSnapsTheControlsBack() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let model = try await connected(sim)
        var rng = SplitMix64(state: 2026)
        for round in 0..<60 {
            let level = Double(Int.random(in: 0...100, using: &rng)) / 10
            let button = Int.random(in: 1...8, using: &rng)
            model.setFader(level)
            model.pressButton(button)
            model.toggleMute()
            let muted = model.muted
            for _ in 0..<Int.random(in: 1...12, using: &rng) {
                try await Task.sleep(for: .milliseconds(50))
                #expect(model.fader == level, "round \(round): fader jumped to \(model.fader)")
                #expect(model.formatButton == button, "round \(round): button jumped")
                #expect(model.muted == muted, "round \(round): mute jumped")
            }
        }
        #expect(await settles(model, sim, on: wire(model.fader)))
        await model.disconnect()
    }

    /// 1000 random format presses: the processor ends on the last one.
    @Test func formatButtonStormEndsOnTheLastPress() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let model = try await connected(sim)
        var rng = SplitMix64(state: 10)
        var last = 1
        for step in 0..<1000 {
            last = Int.random(in: 1...8, using: &rng)
            model.pressButton(last)
            if step % 50 == 0 { await Task.yield() }
        }
        #expect(model.formatButton == last)
        let expected = String(last - 1)
        #expect(await eventually(30) { await probe(sim, "format_button") == expected },
                "processor should end on button \(last)")
        try await Task.sleep(for: .seconds(2.5))
        #expect(model.formatButton == last)
        await model.disconnect()
    }

    /// 1001 mute toggles (odd: ends muted).
    @Test func muteStormEndsOnTheShownState() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let model = try await connected(sim)
        for step in 0..<1001 {
            model.toggleMute()
            if step % 50 == 0 { await Task.yield() }
        }
        #expect(model.muted)
        #expect(await eventually(30) { await probe(sim, "mute") == "1" })
        try await Task.sleep(for: .seconds(2.5))
        #expect(model.muted)
        await model.disconnect()
    }

    /// The link is cut five times in the middle of a knob storm: the app
    /// reconnects by itself and the processor ends on the shown value.
    @Test func linkDropsDuringAKnobStorm() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let model = try await connected(sim)
        var rng = SplitMix64(state: 750)
        model.beginKnobTurn()
        for round in 0..<5 {
            for _ in 0..<400 { model.turnKnob(byDegrees: Double.random(in: -15...16, using: &rng)) }
            try await Task.sleep(for: .milliseconds(150))
            sim.dropConnections()
            for _ in 0..<400 { model.turnKnob(byDegrees: Double.random(in: -15...16, using: &rng)) }
            try await Task.sleep(for: .milliseconds(100 + 50 * round))
        }
        model.endKnobTurn()
        #expect(await eventually(15) { model.isConnected })
        // A SET lost with the link is not resent by design (only queued ones
        // survive); one more step after the storm puts the shown value back.
        model.stepKnob(up: true)
        model.stepKnob(up: false)
        #expect(await settles(model, sim, on: wire(model.fader)))
        await model.disconnect()
    }

    /// The simulator is killed and comes back on the same port.
    @Test func processorRestartIsRecovered() async throws {
        let sim = try await Simulator()
        let model = try await connected(sim)
        let port = sim.port
        sim.stop()
        #expect(await eventually(10) { !model.isConnected })
        let again = try await Simulator(port: port)
        defer { again.stop() }
        #expect(await eventually(15) { model.isConnected })
        model.setFader(4.2)
        #expect(await settles(model, again, on: "42"))
        await model.disconnect()
    }

    /// 50 connect/disconnect cycles, some interleaved with presses.
    @Test func connectDisconnectCycles() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let model = makeModel(sim)
        for cycle in 0..<50 {
            await model.connect()
            #expect(await eventually { model.isConnected }, "cycle \(cycle)")
            if cycle % 5 == 0 {
                model.pressButton(cycle % 8 + 1)
                model.setFader(Double(cycle % 10))
            }
            await model.disconnect()
            #expect(!model.isConnected)
        }
        await model.connect()
        #expect(!model.panelRead)   // a fresh link starts unread...
        #expect(await eventually { model.isConnected })   // ...and is read
        model.setFader(6.5)
        #expect(await settles(model, sim, on: "65"))
        await model.disconnect()
    }

    /// Reconnect hammered from Setup while the knob turns.
    @Test func reconnectStormWhileTurning() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let model = try await connected(sim)
        for _ in 0..<20 {
            model.beginKnobTurn()
            for _ in 0..<100 { model.turnKnob(byDegrees: 3) }
            model.endKnobTurn()
            await model.connect()
        }
        #expect(await eventually { model.isConnected })
        model.setFader(3.3)
        #expect(await settles(model, sim, on: "33"))
        await model.disconnect()
    }

    /// A processor that accepts the link and never answers: connect returns
    /// at once and the panel stays usable.
    @Test func silentProcessorDoesNotBlockConnect() async throws {
        let sim = try await Simulator(extraArguments: ["--silent"])
        defer { sim.stop() }
        let model = makeModel(sim)
        let started = ContinuousClock.now
        await model.connect()
        let took = ContinuousClock.now - started
        #expect(took < .seconds(3), "connect took \(took)")
        await model.disconnect()
    }

    /// Test in the Setup sheet: a running processor, a closed port.
    @Test func setupTestButton() async throws {
        let sim = try await Simulator()
        let model = makeModel(sim)
        let ok = await model.test(address: "127.0.0.1")
        #expect(ok.hasPrefix("OK"), "\(ok)")
        #expect(ok.hasSuffix("fader 7.0."), "\(ok)")
        sim.stop()
        let started = ContinuousClock.now
        let missing = await model.test(address: "127.0.0.1")
        #expect(missing.hasPrefix("No connection"), "\(missing)")
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(await model.test(address: "   ") == "Type an IP address first.")
    }

    /// 20 s of mixed use, one action every 2 ms (knob turns, format presses,
    /// mute toggles) while polling runs and the link is cut every 3 s. At the
    /// end the processor holds exactly what the panel shows.
    @Test func sustainedMixedStormWithLinkDrops() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let model = try await connected(sim)
        var rng = SplitMix64(state: 950)
        var actions = (turns: 0, presses: 0, mutes: 0, drops: 0)
        let end = ContinuousClock.now + .seconds(20)
        var nextDrop = ContinuousClock.now + .seconds(3)
        var turning = false
        while ContinuousClock.now < end {
            switch Int.random(in: 0..<100, using: &rng) {
            case 0..<80:
                if !turning { model.beginKnobTurn(); turning = true }
                model.turnKnob(byDegrees: Double.random(in: -12...12.5, using: &rng))
                actions.turns += 1
            case 80..<85:
                if turning { model.endKnobTurn(); turning = false }
            case 85..<95:
                model.pressButton(Int.random(in: 1...8, using: &rng))
                actions.presses += 1
            default:
                model.toggleMute()
                actions.mutes += 1
            }
            if ContinuousClock.now >= nextDrop {
                sim.dropConnections()
                actions.drops += 1
                nextDrop = ContinuousClock.now + .seconds(3)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        if turning { model.endKnobTurn() }
        print("mixed storm: \(actions.turns) turns, \(actions.presses) presses, "
              + "\(actions.mutes) mute toggles, \(actions.drops) link drops, "
              + "\(sim.setsReceived("fader_level")) fader SETs on the wire")
        #expect(await eventually(15) { model.isConnected })
        // Commands lost with a cut link are not resent (by design); one more
        // touch of each control after the storm puts the shown state back.
        let format = try #require(model.formatButton)
        model.pressButton(format)
        model.toggleMute()
        model.toggleMute()
        model.stepKnob(up: true)
        model.stepKnob(up: false)
        #expect(await settles(model, sim, on: wire(model.fader)))
        let mute = model.muted ? "1" : "0"
        #expect(await eventually(10) { await probe(sim, "format_button") == String(format - 1) })
        #expect(await eventually(10) { await probe(sim, "mute") == mute })
        try await Task.sleep(for: .seconds(2.5))
        #expect(model.formatButton == format)
        #expect(model.muted == (mute == "1"))
        let onWire = await probe(sim, "fader_level")
        if onWire != wire(model.fader) {
            print("MISMATCH model \(wire(model.fader)) processor \(onWire ?? "nil")")
            print(sim.tail(40))
        }
        #expect(onWire == wire(model.fader))
        await model.disconnect()
    }

    /// Connected, Test asks over the main link instead of opening a second
    /// one (the CP650 serves one control client).
    @Test func testUsesTheMainLinkWhenConnected() async throws {
        let sim = try await Simulator(control: true)
        defer { sim.stop() }
        let model = try await connected(sim)
        #expect(await sim.connections() == 1)
        let result = await model.test(address: "127.0.0.1")
        #expect(result.hasPrefix("OK: the connected CP650"), "\(result)")
        #expect(await sim.connections() == 1)
        await model.disconnect()
    }

    /// The processor is off at connect and comes up later: found by itself.
    @Test func failedConnectIsRetried() async throws {
        let first = try await Simulator()
        let port = first.port
        first.stop()
        let suite = UserDefaults(suiteName: "CPRemoteTests")!
        suite.removePersistentDomain(forName: "CPRemoteTests")
        let model = RemoteModel(defaults: suite, port: port, log: nil)
        model.host = "127.0.0.1"
        await model.connect()
        #expect(!model.isConnected)
        try await Task.sleep(for: .seconds(1))
        let sim = try await Simulator(port: port)
        defer { sim.stop() }
        #expect(await eventually(15) { model.isConnected })
        await model.disconnect()
    }

    /// The control session hangs with the socket open: the model reopens
    /// the link, and recovers when the processor answers again.
    @Test func hungLinkIsReopened() async throws {
        let sim = try await Simulator(control: true)
        defer { sim.stop() }
        let model = try await connected(sim)
        #expect(await sim.command("set silent 1") == "OK\n")
        #expect(await eventually(15) { !model.isConnected })
        #expect(await eventually(40) { model.linkReopens >= 1 })
        #expect(await sim.command("set silent 0") == "OK\n")
        #expect(await eventually(20) { model.isConnected })
        await model.disconnect()
    }

    /// Replies that are not a usable level never reach the panel, and no
    /// touch can crash on them.
    @Test func badFaderRepliesAreRejected() async throws {
        let nan = try await Simulator(extraArguments: ["--seed", "fader_level=nan"])
        let model = makeModel(nan)
        await model.connect()
        try await Task.sleep(for: .seconds(3))
        #expect(!model.panelRead)
        #expect(!model.isConnected)
        #expect(model.fader.isFinite)
        model.stepKnob(up: true)
        model.setFader(.nan)
        model.turnKnob(byDegrees: .infinity)
        #expect(model.fader.isFinite)
        await model.disconnect()
        nan.stop()

        let high = try await Simulator(extraArguments: ["--seed", "fader_level=250", "--no-clip"])
        defer { high.stop() }
        let clamped = makeModel(high)
        await clamped.connect()
        #expect(await eventually { clamped.isConnected })
        #expect(clamped.fader == 10.0)
        await clamped.disconnect()
        #expect(RemoteModel.faderLevel("-5") == 0)
        #expect(RemoteModel.faderLevel("inf") == nil)
        #expect(RemoteModel.faderLevel("abc") == nil)
    }

    /// Connect, Reconnect and Disconnect fired at once, 30 of them: they
    /// run one after another, and exactly one link is left.
    @Test func lifecycleCallsAreSerialized() async throws {
        let sim = try await Simulator(control: true)
        defer { sim.stop() }
        let model = makeModel(sim)
        var rng = SplitMix64(state: 30)
        var calls: [Task<Void, Never>] = []
        for _ in 0..<30 {
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: calls.append(Task { await model.connect() })
            case 1: calls.append(Task { await model.reconnect() })
            default: calls.append(Task { await model.disconnect() })
            }
        }
        for call in calls { await call.value }
        await model.connect()
        #expect(await eventually { model.isConnected })
        try await Task.sleep(for: .seconds(1))
        #expect(await sim.connections() == 1)
        await model.disconnect()
        #expect(await eventually { await sim.connections() == 0 })
    }

    /// Ten app windows' worth of models on one processor at once.
    @Test func tenModelsOnOneProcessor() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        var models: [RemoteModel] = []
        for _ in 0..<10 { models.append(try await connected(sim)) }
        for (index, model) in models.enumerated() { model.pressButton(index % 8 + 1) }
        let last = models[9]
        last.setFader(8.8)
        #expect(await settles(last, sim, on: "88"))
        for model in models { await model.disconnect() }
    }
}

/// The CP750 and the CP950 (its CP850 / CP950 front): each model's own
/// parameter names and scales, as their manuals give them, against the
/// simulator.
@MainActor
@Suite(.serialized, .enabled(if: simulatorPath != nil, "needs cpp/build/processor_sim or $CPSIM_BIN"))
struct OtherProcessorTests {
    @Test func cp750ReadsAndDrivesItsPanel() async throws {
        let sim = try await Simulator(model: .cp750)
        defer { sim.stop() }
        let model = makeModel(sim)
        await model.connect()
        #expect(await eventually { model.isConnected && model.formatButton != nil })
        #expect(model.fader == 7.0)                     // cp750.sys.fader 70
        #expect(model.formatButton == 5)                // cp750.sys.input_mode analog
        #expect(model.currentInputName == "Multi-Ch Analog")
        #expect(model.muted == false)                   // cp750.sys.mute 0

        model.pressButton(2)                            // Digital 2
        #expect(await eventually { await probe(sim, "cp750.sys.input_mode") == "dig_2" })
        model.pressButton(7)                            // Mic
        #expect(await eventually { await probe(sim, "cp750.sys.input_mode") == "mic" })
        #expect(await eventually { model.formatButton == 7 })

        model.setFader(4.5)
        #expect(await eventually(10) { await probe(sim, "cp750.sys.fader") == "45" })
        model.toggleMute()
        #expect(await eventually(10) { await probe(sim, "cp750.sys.mute") == "1" })
        #expect(model.muted)
        await model.disconnect()
    }

    /// The CP950's fader takes 1 to 100 (0.1 to 10.0): a zero is held at 0.1.
    @Test func cp950ReadsAndDrivesItsFader() async throws {
        let sim = try await Simulator(model: .cp950)
        defer { sim.stop() }
        let model = makeModel(sim)
        await model.connect()
        #expect(await eventually { model.isConnected })
        #expect(model.fader == 7.0)                     // sys.fader 70
        #expect(model.muted == false)                   // sys.mute 0

        model.setFader(4.5)
        #expect(await eventually(10) { await probe(sim, "sys.fader") == "45" })
        model.setFader(0)
        #expect(model.fader == 0.1)
        #expect(await eventually(10) { await probe(sim, "sys.fader") == "1" })

        model.toggleMute()
        #expect(await eventually(10) { await probe(sim, "sys.mute") == "1" })
        #expect(model.muted)
        model.toggleMute()
        #expect(await eventually(10) { await probe(sim, "sys.mute") == "0" })
        await model.disconnect()
    }
}

/// Every front-panel control of each processor, pressed one by one against
/// the simulator, and the processor's own value checked for each.
@MainActor
@Suite(.serialized, .enabled(if: simulatorPath != nil, "needs cpp/build/processor_sim or $CPSIM_BIN"))
struct EveryControlTests {
    @Test func cp650EveryFormatButtonAndMute() async throws {
        let sim = try await Simulator(model: .cp650)
        defer { sim.stop() }
        let model = makeModel(sim)
        await model.connect()
        #expect(await eventually { model.isConnected && model.programmedFormats != nil })
        #expect(model.programmedFormats == ["01", "04", "05", "10", "93", "94", "95", "99"])
        for button in 1...8 {
            model.pressButton(button)
            #expect(await eventually { await probe(sim, "format_button") == String(button - 1) },
                    "format button \(button)")
            #expect(model.currentFormat == model.programmedFormats?[button - 1])
        }
        model.toggleMute()
        #expect(await eventually { await probe(sim, "mute") == "1" })
        model.toggleMute()
        #expect(await eventually { await probe(sim, "mute") == "0" })
        await model.disconnect()
    }

    /// The CP650 as the manual describes it: format_button takes 0 to 7. With
    /// the old 1 to 8 numbering, button 8 answered `error` and was lost.
    @Test func cp650StrictSimulatorTakesEveryFormatButton() async throws {
        let sim = try await Simulator(model: .cp650, extraArguments: ["--strict-cp650"])
        defer { sim.stop() }
        for button in [1, 5, 8] {
            let model = makeModel(sim)
            await model.connect()
            #expect(await eventually { model.isConnected && model.formatButton != nil })
            model.pressButton(button)
            try await Task.sleep(for: .seconds(1))
            await model.disconnect()
            #expect(await eventually { await probe(sim, "format_button") == String(button - 1) },
                    "format button \(button)")
        }
    }

    @Test func cp750EverySevenInputAndMute() async throws {
        let sim = try await Simulator(model: .cp750)
        defer { sim.stop() }
        let model = makeModel(sim)
        await model.connect()
        #expect(await eventually { model.isConnected })
        let names = ["Digital 1", "Digital 2", "Digital 3", "Digital 4", "Multi-Ch Analog", "NonSync", "Mic"]
        let values = ["dig_1", "dig_2", "dig_3", "dig_4", "analog", "non_sync", "mic"]
        for button in 1...7 {
            model.pressButton(button)
            #expect(await eventually { await probe(sim, "cp750.sys.input_mode") == values[button - 1] },
                    "input \(names[button - 1])")
            #expect(model.currentInputName == names[button - 1])
        }
        model.toggleMute()
        #expect(await eventually { await probe(sim, "cp750.sys.mute") == "1" })
        model.toggleMute()
        #expect(await eventually { await probe(sim, "cp750.sys.mute") == "0" })
        #expect(model.muted == false)
        await model.disconnect()
    }

    @Test func cp950FaderSweepAndMute() async throws {
        let sim = try await Simulator(model: .cp950)
        defer { sim.stop() }
        let model = makeModel(sim)
        await model.connect()
        #expect(await eventually { model.isConnected })
        for tenths in [1, 25, 70, 100] {
            model.setFader(Double(tenths) / 10)
            #expect(await eventually(10) { await probe(sim, "sys.fader") == String(tenths) },
                    "fader \(tenths)")
            #expect(model.fader == Double(tenths) / 10)
        }
        model.toggleMute()
        #expect(await eventually { await probe(sim, "sys.mute") == "1" })
        model.toggleMute()
        #expect(await eventually { await probe(sim, "sys.mute") == "0" })
        await model.disconnect()
    }
}

/// The CP850 and CP950A, each against the simulator with its own names and
/// values, the same checks as the CP950.
@MainActor
@Suite(.serialized, .enabled(if: simulatorPath != nil, "needs CPSIM_BIN (the simulator)"))
struct CP850AndCP950ATests {
    @Test(arguments: [ProcessorModel.cp850, .cp950a])
    func readsDrivesAndMutes(_ processor: ProcessorModel) async throws {
        let sim = try await Simulator(model: processor)
        defer { sim.stop() }
        let model = makeModel(sim)
        await model.connect()
        #expect(await eventually { model.isConnected })
        #expect(model.fader == 7.0)
        #expect(model.muted == false)

        model.setFader(4.5)
        #expect(await eventually(10) { await probe(sim, "sys.fader") == "45" })
        model.setFader(0)
        #expect(await eventually(10) { await probe(sim, "sys.fader") == "1" })
        model.toggleMute()
        #expect(await eventually(10) { await probe(sim, "sys.mute") == "1" })
        #expect(model.muted)
        await model.disconnect()
    }
}

/// The app's choices survive a restart: the model and the address are stored
/// in the defaults and read back by a new model.
@MainActor
@Suite struct PersistenceTests {
    @Test func modelAndAddressAreRemembered() {
        let suite = "CPRemoteTests.persistence"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let first = RemoteModel(defaults: defaults, log: nil)
        first.host = "10.0.0.5"
        first.choose(.cp750)
        let second = RemoteModel(defaults: defaults, log: nil)
        #expect(second.host == "10.0.0.5")
        #expect(second.processorModel == .cp750)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func unknownStoredModelFallsBackToTheCP650() {
        let suite = "CPRemoteTests.fallback"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("CP999", forKey: "processorModel")
        #expect(RemoteModel(defaults: defaults, log: nil).processorModel == .cp650)
        defaults.removePersistentDomain(forName: suite)
    }
}

/// A cut link is found again by the app, with its values intact.
@MainActor
@Suite(.serialized, .enabled(if: simulatorPath != nil, "needs CPSIM_BIN (the simulator)"))
struct ReconnectAfterCutTests {
    @Test func valuesSurviveACutLink() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let model = try await connected(sim)
        model.setFader(4.5)
        #expect(await eventually(10) { await probe(sim, "fader_level") == "45" })
        sim.dropConnections()
        #expect(await eventually(20) { model.isConnected })
        #expect(await eventually(10) { model.fader == 4.5 })
        #expect(await probe(sim, "fader_level") == "45")
        await model.disconnect()
    }
}

/// Every front panel draws, the same way twice (a blank or unstable panel
/// fails here). The pictures are not kept.
@MainActor
@Suite struct PanelRenderTests {
    @Test(arguments: [ProcessorModel.cp650, .cp750, .cp950])
    func frontDrawsDeterministically(_ processor: ProcessorModel) throws {
        let model = RemoteModel(defaults: UserDefaults(suiteName: "CPRemoteTests.render")!, log: nil)
        model.choose(processor)
        let width: CGFloat = 900
        let size = CGSize(width: width, height: width / processor.aspect)
        func render() throws -> Data {
            let renderer = ImageRenderer(content: FrontPanelView(model: model).frame(width: size.width, height: size.height))
            renderer.scale = 1
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let first = try render()
        let second = try render()
        #expect(first.count > 20_000, "a blank panel would be almost empty")
        #expect(first == second, "the same state must draw the same picture")
    }
}

/// The connection log: its file, its rotation, and what the app and its link
/// write into it.
@MainActor
@Suite struct ConnectionLogTests {
    private func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CPRemoteLogTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func linesAreTimestampedAndKeptInOrder() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = ConnectionLog(directory: folder)
        log.write("first")
        log.write("second")
        log.flush()
        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix(" first") && lines[1].hasSuffix(" second"))
        // 2026-11-10T11:22:25.123Z: the time, to the millisecond, in UTC.
        #expect(lines[0].range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z "#, options: .regularExpression) != nil)
    }

    @Test func theFileRotatesAndNeverGrowsWithoutLimit() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = ConnectionLog(directory: folder, maximumBytes: 2_000)
        for number in 0..<400 { log.write("line number \(number) with some padding to fill the file") }
        log.flush()
        let sizes = ["connection.log", "connection.log.1"].map {
            (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path))?[.size] as? Int ?? 0
        }
        #expect(sizes[1] > 0, "the older file exists")
        #expect(sizes[0] <= 2_000 + 200 && sizes[1] <= 2_000 + 200, "each file stays near the limit")
        let newest = try String(contentsOf: log.url, encoding: .utf8)
        #expect(newest.contains("line number 399"), "the newest line is kept")
    }

    /// Connect to the simulator with a real log: the file shows the lines the
    /// link sent and received, the status change with its reason, and the
    /// moment the panel was read.
    @Test(.enabled(if: simulatorPath != nil, "needs CPSIM_BIN (the simulator)"))
    func appAndLinkWriteToTheLog() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = ConnectionLog(directory: folder)
        let suite = "CPRemoteTests.logging"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = RemoteModel(defaults: defaults, port: sim.port, log: log)
        model.host = "127.0.0.1"
        await model.connect()
        #expect(await eventually { model.isConnected })
        await model.disconnect()
        log.flush()
        let text = try String(contentsOf: log.url, encoding: .utf8)
        for expected in ["app: connect to 127.0.0.1 as CP650", "link: connect succeeded",
                         "link: status initializing -> ok (connect)", "link: send fader_level=?",
                         "link: recv fader_level=70", "app: panel read: controls enabled",
                         "app: disconnect requested"] {
            #expect(text.contains(expected), "missing: \(expected)")
        }
        defaults.removePersistentDomain(forName: suite)
    }
}

/// A real unit can take more than half a second to answer a SET (a mute
/// fades, a format change reconfigures it). That must not be taken as a lost
/// link: the controls stay enabled and the change still arrives.
@MainActor
@Suite(.serialized, .enabled(if: simulatorPath != nil, "needs CPSIM_BIN (the simulator)"))
struct SlowReplyTests {
    @Test func aSlowReplyToASetKeepsTheControlsEnabled() async throws {
        let sim = try await Simulator(control: true)
        defer { sim.stop() }
        let model = try await connected(sim)
        #expect(await sim.command("set latency 0.8") == "OK\n")
        model.toggleMute()
        // Four seconds, long enough for the SET and the polls behind it.
        for step in 0..<16 {
            try await Task.sleep(for: .milliseconds(250))
            #expect(model.isConnected, "controls disabled at \(step * 250) ms after the SET")
        }
        #expect(await sim.command("set latency 0") == "OK\n")
        #expect(await eventually(10) { await probe(sim, "mute") == "1" })
        await model.disconnect()
    }
}

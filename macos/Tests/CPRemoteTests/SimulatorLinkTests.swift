// The app's model against the CPSeries processor simulator, over the real
// cpseries library. They run only when CPSIM_PORT_CP650, CPSIM_PORT_CP750 and
// CPSIM_PORT_CP950 name the ports of running simulators of those models.

import Foundation
import Testing

@testable import CPRemote

private func simulatorPort(_ model: ProcessorModel) -> UInt16? {
    ProcessInfo.processInfo.environment["CPSIM_PORT_\(model.rawValue)"].flatMap(UInt16.init)
}

private let simulatorsRunning = [ProcessorModel.cp650, .cp750, .cp950].allSatisfy { simulatorPort($0) != nil }

/// Wait until `condition` holds, at most `seconds`.
@MainActor
private func waitFor(_ seconds: Double = 12, _ condition: () -> Bool) async -> Bool {
    let end = Monotonic.Instant.now + seconds
    while Monotonic.Instant.now < end {
        if condition() { return true }
        await Monotonic.sleep(for: 0.05)
    }
    return condition()
}

/// A second link to the simulator, to read what the app sent.
private func read(_ param: String, _ model: ProcessorModel) async -> String? {
    let link = ProcessorLink(host: "127.0.0.1", port: simulatorPort(model), model: model)
    guard await link.connect() else { return nil }
    let value = await link.get(param)
    await link.disconnect()
    return value
}

/// Read `param` until it is `expected`, at most `seconds`: the CP650 takes one
/// connection, so a read right after a disconnect may find it still busy.
private func readEventually(
    _ param: String, _ model: ProcessorModel, equals expected: String, within seconds: Double = 8
) async -> Bool {
    let end = Monotonic.Instant.now + seconds
    while Monotonic.Instant.now < end {
        if await read(param, model) == expected { return true }
        await Monotonic.sleep(for: 0.2)
    }
    return false
}

@MainActor
private func connectedModel(_ processor: ProcessorModel) async throws -> RemoteModel {
    let suite = "CPRemoteTests.sim.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = RemoteModel(defaults: defaults, port: simulatorPort(processor), log: nil, reopenPause: 0.5)
    model.host = "127.0.0.1"
    model.choose(processor)
    await model.connect()
    try #require(await waitFor { model.isConnected }, "the panel is read and the controls come on")
    return model
}

@MainActor
@Suite(.enabled(if: simulatorsRunning), .serialized)
struct SimulatorLinkTests {
    @Test func cp750ReadsAndSendsTheFaderMuteAndInput() async throws {
        let model = try await connectedModel(.cp750)
        #expect(model.fader == 5.5, "seeded cp750.sys.fader=55")
        model.setFader(6.0)
        model.toggleMute()
        model.pressButton(2)
        #expect(await waitFor { model.faderIsSettled && model.sending.isEmpty }, "every send is through")
        await model.disconnect()
        #expect(await readEventually("cp750.sys.fader", .cp750, equals: "60"))
        #expect(await readEventually("cp750.sys.mute", .cp750, equals: "1"))
        #expect(await readEventually("cp750.sys.input_mode", .cp750, equals: "dig_2"))
    }

    @Test func cp950ShowsTheSelectedMacro() async throws {
        let model = try await connectedModel(.cp950)
        #expect(await waitFor { model.macroName != nil })
        #expect(model.macroPreset == 3)
        #expect(model.macroName == "Feature")
        model.selectMacro(4)
        #expect(await waitFor { model.sending.isEmpty }, "the macro send is through")
        await model.disconnect()
        #expect(await readEventually("sys.macro_preset", .cp950, equals: "4"))
    }

    @Test func cp650ReadsTheFormatsAndSelectsAButton() async throws {
        let model = try await connectedModel(.cp650)
        #expect(model.fader == 7.0)
        #expect(await waitFor { model.programmedFormats != nil })
        model.pressButton(4)
        #expect(await waitFor { model.sending.isEmpty }, "the button send is through")
        #expect(await model.test(address: "127.0.0.1").hasPrefix("OK: the connected CP650"))
        await model.disconnect()
        #expect(await readEventually("format_button", .cp650, equals: "3"))
    }

    @Test func testButtonReportsAMissingProcessor() async throws {
        let suite = "CPRemoteTests.sim.none"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Port 9 (discard) is closed on a normal Mac, so nothing answers there.
        let model = RemoteModel(defaults: defaults, port: 9, log: nil)
        #expect(await model.test(address: "127.0.0.1", model: .cp750).hasPrefix("No connection"))
    }
}

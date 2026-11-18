import Foundation
import Testing
@testable import CPx50Comms

/// What the link's event log records, against the simulator.
@Suite(.serialized, .enabled(if: simulatorPath != nil, "needs CPSIM_BIN (the simulator)"))
struct EventLogTests {
    /// Collects the events of one client.
    private final class Collector: @unchecked Sendable {
        private let lock = Locked<[String]>([])
        func add(_ line: String) { lock.withLock { $0.append(line) } }
        var lines: [String] { lock.withLock { $0 } }
    }

    @Test func recordsLinesStatusAndTimeouts() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let events = Collector()
        let cp = fastClient(sim.port, getRetries: 0)
        await cp.setEventLog { events.add($0) }
        #expect(await cp.connect())
        #expect(try await cp.get("fader_level", timeout: 0.5) == "70")
        #expect(try await cp.get("no_such_param", timeout: 0.3) == nil)
        await cp.disconnect()

        let text = events.lines.joined(separator: "\n")
        for expected in ["connect succeeded", "status initializing -> ok (connect)", "send fader_level?",
                         "recv fader_level=70", "send no_such_param?", "recv <nothing within 0.3 s>",
                         "disconnect"] {
            #expect(text.contains(expected), "missing: \(expected)\n\(text)")
        }
    }

    /// A CP650 that answers only `KEY=?`: each query falls back to it on its
    /// retry; after two queries left unanswered in the preferred form, every
    /// later query is sent that way from the start.
    @Test func aCP650ThatAnswersOnlyTheEqualsFormIsLearned() async throws {
        let sim = try await Simulator(extraArguments: ["--query-form", "equals", "--log"])
        defer { sim.stop() }
        let events = Collector()
        let cp = fastClient(sim.port, getRetries: 1)
        await cp.setEventLog { events.add($0) }
        #expect(await cp.connect())
        #expect(try await cp.get("fader_level", timeout: 0.3) == "70")
        #expect(!events.lines.contains { $0.hasPrefix("queries are sent as") }, "one miss must not switch")
        #expect(try await cp.get("mute", timeout: 0.3) == "0")
        #expect(events.lines.contains("queries are sent as mute=? from now on"))
        let before = sim.received().count
        #expect(try await cp.get("format_button", timeout: 0.3) == "0")
        #expect(Array(sim.received().dropFirst(before)) == ["format_button=?"])
        await cp.disconnect()
    }

    /// A CP650 that answers only `KEY?` (as the unit that ran 1.0 did): one
    /// query, no retry, no switch.
    @Test func aCP650ThatAnswersOnlyTheBareFormIsAnsweredAtOnce() async throws {
        let sim = try await Simulator(extraArguments: ["--query-form", "bare", "--log"])
        defer { sim.stop() }
        let cp = fastClient(sim.port, getRetries: 0)
        #expect(await cp.connect())
        #expect(try await cp.get("fader_level", timeout: 0.3) == "70")
        #expect(try await cp.get("mute", timeout: 0.3) == "0")
        #expect(sim.received() == ["fader_level?", "mute?"])
        await cp.disconnect()
    }

    @Test func switchingTheLogOffStopsTheEvents() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let events = Collector()
        let cp = fastClient(sim.port)
        await cp.setEventLog { events.add($0) }
        #expect(await cp.connect())
        #expect(!events.lines.isEmpty, "the log must have recorded the connect")
        await cp.setEventLog(nil)
        let before = events.lines.count
        _ = try await cp.get("fader_level", timeout: 0.5)
        #expect(events.lines.count == before)
        await cp.disconnect()
    }
}

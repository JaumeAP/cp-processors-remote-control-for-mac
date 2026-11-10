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

import Foundation
import Testing
@testable import CPx50Comms

/// A connect that failed at once on a real Mac (report of 2026-11-19) left
/// only "connect failed" in the log; the reason is now recorded.
@Suite(.serialized, .enabled(if: simulatorPath != nil, "needs CPSIM_BIN (the simulator)"))
struct ConnectFailureReasonTests {
    private final class Collector: @unchecked Sendable {
        private let lock = Locked<[String]>([])
        func add(_ line: String) { lock.withLock { $0.append(line) } }
        var lines: [String] { lock.withLock { $0 } }
    }

    /// A port nothing listens on: the free port a just-stopped simulator held.
    private func closedPort() async throws -> UInt16 {
        let sim = try await Simulator()
        let port = sim.port
        sim.stop()
        return port
    }

    @Test func aFailedConnectSaysWhy() async throws {
        let transport = TCPTransport(host: "127.0.0.1", port: try await closedPort(), connectTimeout: 2)
        #expect(await transport.connect() == false)
        let reason = await transport.lastConnectFailure()
        #expect(reason?.isEmpty == false)
    }

    @Test func aSuccessfulConnectClearsTheReason() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let transport = TCPTransport(host: "127.0.0.1", port: sim.port)
        #expect(await transport.connect())
        #expect(await transport.lastConnectFailure() == nil)
        await transport.close()
    }

    @Test func theEventLogCarriesTheReason() async throws {
        let events = Collector()
        let cp = fastClient(try await closedPort())
        await cp.setEventLog { events.add($0) }
        #expect(await cp.connect() == false)
        #expect(events.lines.contains { $0.hasPrefix("connect failed (") }, "\(events.lines)")
    }
}

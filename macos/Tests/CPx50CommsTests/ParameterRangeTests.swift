import Foundation
import Testing
@testable import CPx50Comms

/// Public times and counts that used to trap (Duration.seconds on an
/// infinite or huge value, a Range with a negative bound) are made safe.
@Suite struct ParameterRangeTests {
    @Test func timesAreClamped() {
        #expect(ProtocolTiming.clamped(.infinity) == ProtocolTiming.longestWait)
        #expect(ProtocolTiming.clamped(1e30) == ProtocolTiming.longestWait)
        #expect(ProtocolTiming.clamped(-5) == 0)
        #expect(ProtocolTiming.clamped(.nan) == 0)
        #expect(ProtocolTiming.clamped(-.infinity, floor: 0.01) == 0.01)
        #expect(ProtocolTiming.clamped(1.5) == 1.5)
        #expect(ProtocolTiming.clampedRetries(-2) == 0)
        #expect(ProtocolTiming.clampedRetries(.max) == 100)
    }

    /// A client built with extreme values: building it, connecting, a get
    /// and a set must neither trap nor hang.
    @Test(.enabled(if: simulatorPath != nil, "needs CPSIM_BIN (the simulator)"))
    func aClientWithExtremeValuesDoesNotTrap() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = DolbyCP(host: "127.0.0.1", port: sim.port, model: .cp650, pollInterval: .infinity,
                         pollParam: "mute", watchdog: .infinity, autoReconnect: true,
                         reconnectBackoff: (-1, .infinity), getRetries: -2, gap: .nan)
        await cp.setReopenPause(.infinity)
        #expect(cp.getRetries == 0)
        #expect(cp.pollInterval == ProtocolTiming.longestWait)
        #expect(await cp.connect())
        #expect(try await cp.get("mute", timeout: 0.5) == "0")
        #expect(try await cp.set("mute", 1, timeout: .infinity))
        #expect(await cp.settle(timeout: 3))
        await cp.disconnect()
        let transport = TCPTransport(host: "127.0.0.1", port: sim.port, connectTimeout: .infinity,
                                     writeTimeout: .nan)
        #expect(await transport.connect())
        #expect(await transport.readLine(timeout: -1) == nil)
        await transport.close()
    }
}

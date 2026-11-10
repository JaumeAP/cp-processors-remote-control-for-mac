import Foundation
import Testing
@testable import CPx50Comms

/// A transport that always connects (after a short delay, so calls overlap),
/// never replies, and counts what it is asked.
private actor CountingTransport: LineTransport {
    private(set) var connects = 0
    private(set) var closes = 0
    private var connected = false

    func isConnected() -> Bool { connected }
    func peerClosed() -> Bool { false }

    func connect() async -> Bool {
        connects += 1
        try? await Task.sleep(for: .milliseconds(20))
        connected = true
        return true
    }

    func sendLine(_ line: String) async throws {}

    /// Waits out the whole timeout (no reply ever comes), so a query holds the link.
    func readLine(timeout: Double) async -> String? {
        try? await Task.sleep(for: .seconds(timeout))
        return nil
    }

    func close() {
        closes += 1
        connected = false
    }

    /// Drop the link as if it failed, so a watchdog with auto-reconnect acts.
    func fail() { connected = false }
}

/// Lifecycle regressions from the architecture review of the client slice
/// (H1, H3): overlapping lifecycle calls must not leave background tasks
/// running, and nothing may reopen the link after `disconnect()`.
@Suite struct DolbyCPLifecycleTests {
    @Test func overlappingConnectsLeaveNoOrphanedWatchdog() async throws {
        let transport = CountingTransport()
        let cp = DolbyCP(transport: transport, model: .cp850, pollInterval: 0.02,
                         autoReconnect: true, reconnectBackoff: (0.01, 0.02), gap: 0)
        async let first = cp.connect()
        async let second = cp.connect()
        _ = await (first, second)
        await cp.disconnect()
        let before = await transport.connects
        await transport.fail()
        try await Task.sleep(for: .milliseconds(300))   // many watchdog ticks
        #expect(await transport.connects == before, "a watchdog reopened the link after disconnect()")
        #expect(await !cp.isLinkUp)
    }

    @Test func disconnectWhileTheWatchdogWaitsForTheLinkDoesNotReconnect() async throws {
        let transport = CountingTransport()
        let cp = DolbyCP(transport: transport, model: .cp850, pollInterval: 0.02,
                         autoReconnect: true, reconnectBackoff: (0.01, 0.02), getRetries: 0, gap: 0)
        #expect(await cp.connect())
        async let held = cp.get("sys.fader", timeout: 0.3)   // holds the link, never answered
        try await Task.sleep(for: .milliseconds(50))
        await transport.fail()                               // the watchdog now waits for the link to reconnect
        try await Task.sleep(for: .milliseconds(50))
        let before = await transport.connects
        await cp.disconnect()                                // cancels that watchdog while it waits
        _ = try await held
        try await Task.sleep(for: .milliseconds(300))
        #expect(await transport.connects == before, "the cancelled watchdog reconnected")
        #expect(await !cp.isLinkUp)
    }
}

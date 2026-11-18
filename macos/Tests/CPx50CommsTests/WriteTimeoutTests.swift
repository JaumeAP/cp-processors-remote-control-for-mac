import Foundation
import Testing
@testable import CPx50Comms

/// A transport that never replies and fails the first `failures` sends with
/// `failure`, counting every send. As the `LineTransport` contract says, a
/// failed send takes the link down unless it timed out (`TransportFailure`).
private actor FailingTransport: LineTransport {
    private let failure: any Error
    private var failuresLeft: Int
    private var connected = false
    private(set) var sends = 0
    private(set) var connects = 0

    init(failure: any Error, failures: Int = .max) {
        self.failure = failure
        failuresLeft = failures
    }

    func isConnected() -> Bool { connected }
    func peerClosed() -> Bool { false }
    func connect() async -> Bool {
        connects += 1
        connected = true
        return true
    }
    func sendLine(_ line: String) async throws {
        sends += 1
        guard failuresLeft > 0 else { return }
        failuresLeft -= 1
        if (failure as? any TransportFailure)?.isWriteTimeout != true { connected = false }
        throw failure
    }
    func readLine(timeout: Double) async -> String? { nil }
    func close() { connected = false }
}

/// A transport's own failure type, not one of the library's.
private struct CustomFailure: TransportFailure {
    var isWriteTimeout: Bool { true }
}

@Suite struct WriteTimeoutTests {
    private func client(_ transport: FailingTransport, autoReconnect: Bool = false) -> DolbyCP {
        DolbyCP(transport: transport, model: .cp650, pollInterval: 0.05, watchdog: 0.6,
                autoReconnect: autoReconnect, reconnectBackoff: (0.01, 0.05), gap: 0.01)
    }

    /// A write that timed out may have put part of the line on the wire: the
    /// SET is not sent again, whatever transport reported it.
    @Test(arguments: [TCPTransport.Failure.writeTimedOut as any Error,
                      SerialTransport.Failure.writeTimedOut, CustomFailure()])
    func aTimedOutWriteIsNotSentAgain(_ failure: any Error) async throws {
        let transport = FailingTransport(failure: failure)
        let cp = client(transport)
        #expect(await cp.connect())
        #expect(try await cp.set("mute", 1))
        #expect(await eventually(3) { await transport.sends == 1 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(await transport.sends == 1, "a timed-out write must not be repeated (\(failure))")
        #expect(await cp.pendingSets.isEmpty)
        await cp.disconnect()
    }

    /// Any other failed send did not reach the wire and took the link down:
    /// the SET waits for the link to be reopened and is sent again on it.
    @Test func aFailedWriteIsSentAgainAfterTheReconnect() async throws {
        let transport = FailingTransport(failure: TCPTransport.Failure.sendFailed("reset"), failures: 1)
        let cp = client(transport, autoReconnect: true)
        #expect(await cp.connect())
        #expect(try await cp.set("mute", 1))
        #expect(await eventually(3) { await transport.sends == 2 }, "the SET was not sent again")
        #expect(await transport.connects == 2, "it must go out on a reopened link")
        #expect(await cp.settle(timeout: 2))
        await cp.disconnect()
    }
}

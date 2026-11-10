import Foundation
import Testing
@testable import CPx50Comms

/// A transport that is always connected, never replies, and fails every send
/// with `failure`, counting the sends.
private actor FailingTransport: LineTransport {
    private let failure: any Error
    private(set) var sends = 0

    init(failure: any Error) { self.failure = failure }

    func isConnected() -> Bool { true }
    func peerClosed() -> Bool { false }
    func connect() async -> Bool { true }
    func sendLine(_ line: String) async throws {
        sends += 1
        throw failure
    }
    func readLine(timeout: Double) async -> String? { nil }
    func close() {}
}

@Suite struct WriteTimeoutTests {
    private func client(_ transport: FailingTransport) -> DolbyCP {
        DolbyCP(transport: transport, model: .cp650, pollInterval: 0.05, watchdog: 0.6,
                autoReconnect: false, gap: 0.01)
    }

    /// A write that timed out may have put part of the line on the wire: the
    /// SET is not sent again.
    @Test func aTimedOutWriteIsNotSentAgain() async throws {
        for failure in [TCPTransport.Failure.writeTimedOut] {
            let transport = FailingTransport(failure: failure)
            let cp = client(transport)
            #expect(await cp.connect())
            #expect(try await cp.set("mute", 1))
            #expect(await eventually(3) { await transport.sends == 1 })
            try await Task.sleep(for: .milliseconds(500))
            #expect(await transport.sends == 1, "a timed-out write must not be repeated")
            #expect(await cp.pendingSets.isEmpty)
            await cp.disconnect()
        }
        let serial = FailingTransport(failure: SerialTransport.Failure.writeTimedOut)
        let cp = client(serial)
        #expect(await cp.connect())
        #expect(try await cp.set("mute", 1))
        try await Task.sleep(for: .milliseconds(600))
        #expect(await serial.sends == 1, "a timed-out serial write must not be repeated")
        await cp.disconnect()
    }

    /// Any other failed send did not reach the wire: the SET waits for the link
    /// and is sent again.
    @Test func aFailedWriteIsSentAgain() async throws {
        let transport = FailingTransport(failure: TCPTransport.Failure.sendFailed("reset"))
        let cp = client(transport)
        #expect(await cp.connect())
        #expect(try await cp.set("mute", 1))
        #expect(await eventually(3) { await transport.sends >= 2 })
        await cp.disconnect()
    }
}

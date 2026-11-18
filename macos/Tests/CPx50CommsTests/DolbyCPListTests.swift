import Foundation
import Testing
@testable import CPx50Comms

/// A transport that answers each line it is sent with lines from a script,
/// all at once, and is otherwise silent.
private actor ScriptedTransport: LineTransport {
    private let replies: [String: [String]]
    private var pending: [String] = []
    private var connected = false

    init(replies: [String: [String]]) { self.replies = replies }

    func isConnected() -> Bool { connected }
    func peerClosed() -> Bool { false }
    func connect() async -> Bool {
        connected = true
        return true
    }
    func sendLine(_ line: String) async throws { pending += replies[line] ?? [] }
    func readLine(timeout: Double) async -> String? {
        if !pending.isEmpty { return pending.removeFirst() }
        try? await Task.sleep(for: .seconds(min(timeout, 0.05)))
        return nil
    }
    func close() { connected = false }
}

@Suite struct DolbyCPListTests {
    /// A stale line ahead of the header (a late reply, a line the unit pushed)
    /// used to fail the whole read, leaving the header and items behind.
    @Test func aStaleLineBeforeTheHeaderIsSkipped() async throws {
        let transport = ScriptedTransport(replies: [
            "sys.macros ?": ["sys.macro_name Music", "sys.macros", "1: 5.1", "2: Music"],
        ])
        let cp = DolbyCP(transport: transport, model: .cp850, gap: 0)
        #expect(await cp.connect())
        #expect(try await cp.getList("sys.macros", itemTimeout: 0.05) == ["1: 5.1", "2: Music"])
        await cp.disconnect()
    }
}

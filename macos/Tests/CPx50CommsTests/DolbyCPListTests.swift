import Foundation
import Testing
@testable import CPx50Comms

/// A transport that answers each line it is sent with lines from a script,
/// all at once, and is otherwise silent.
private actor ScriptedTransport: LineTransport {
    private let replies: [String: [String]]
    private var pending: [String]
    private var connected = false

    /// `waiting`: lines already in the buffer when the link opens (a late
    /// reply, a line the unit pushed).
    init(replies: [String: [String]], waiting: [String] = []) {
        self.replies = replies
        pending = waiting
    }

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

/// A CP650 SET skips a stray line to its own reply: taken as the reply, the
/// stray line left each later SET's echo and reply behind, and the next fader
/// read got an old level.
@Suite struct DolbyCPSetResyncTests {
    @Test func aStrayLineIsNotTakenAsTheReplyOfASet() async throws {
        let transport = ScriptedTransport(replies: [
            "fader_level=71": ["fader_level=71", "fader_level=71"],         // echo, reply
            "fader_level=72": ["fader_level=72", "fader_level=72"],
            "fader_level?": ["fader_level?", "fader_level=72"],
        ], waiting: ["mute=0"])                                            // a line the unit pushed
        let cp = DolbyCP(transport: transport, model: .cp650, gap: 0)
        #expect(await cp.connect())
        #expect(try await cp.set("fader_level", 71))
        #expect(await cp.settle(timeout: 3))
        #expect(try await cp.set("fader_level", 72))
        #expect(await cp.settle(timeout: 3))
        #expect(try await cp.get("fader_level", timeout: 0.2) == "72", "an old level was read")
        await cp.disconnect()
    }
}

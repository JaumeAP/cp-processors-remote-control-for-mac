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

/// A CP650 that answers `KEY?` only, late: the reply to the first form lands
/// while the retry in the other form waits, and is read as its answer.
private actor LateTransport: LineTransport {
    private var pending: [String] = []
    private var connected = false
    private(set) var sent: [String] = []

    func isConnected() -> Bool { connected }
    func peerClosed() -> Bool { false }
    func connect() async -> Bool {
        connected = true
        return true
    }
    func sendLine(_ line: String) async throws {
        sent.append(line)
        guard line.hasSuffix("?"), !line.hasSuffix("=?") else { return }   // KEY=? is never answered
        let key = String(line.dropLast())
        Task {
            try? await Task.sleep(for: .milliseconds(150))                  // after the 0.1 s timeout
            self.arrive("\(key)=1")
        }
    }
    private func arrive(_ line: String) { pending.append(line) }
    func readLine(timeout: Double) async -> String? {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if !pending.isEmpty { return pending.removeFirst() }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
    func close() { connected = false }
}

@Suite struct DolbyCPQueryFormTests {
    /// One late reply to `KEY?`, read as the answer to the `KEY=?` retry,
    /// used to switch every later query to `KEY=?`, which this unit ignores.
    @Test func aLateReplyDoesNotSwitchTheQueryForm() async throws {
        let transport = LateTransport()
        let cp = DolbyCP(transport: transport, model: .cp650, getRetries: 1, gap: 0)
        #expect(await cp.connect())
        #expect(try await cp.get("mute", timeout: 0.1) == "1")              // answered late
        try await Task.sleep(for: .milliseconds(200))
        let before = await transport.sent.count
        _ = try await cp.get("fader_level", timeout: 0.3)
        #expect(await transport.sent.dropFirst(before).first == "fader_level?", "the form was switched")
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

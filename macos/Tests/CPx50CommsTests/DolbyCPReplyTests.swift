import Foundation
import Testing
@testable import CPx50Comms

/// A transport that answers each line it is sent with the lines `script`
/// gives for it, queued in order; a read with nothing queued waits out its
/// timeout. Counts connects.
private actor ScriptedTransport: LineTransport {
    private let script: @Sendable (String) -> [String]
    private var queue: [String] = []
    private var connected = false
    private(set) var connects = 0

    init(script: @escaping @Sendable (String) -> [String]) {
        self.script = script
    }

    func isConnected() -> Bool { connected }
    func peerClosed() -> Bool { false }

    func connect() async -> Bool {
        connects += 1
        connected = true
        return true
    }

    func sendLine(_ line: String) async throws {
        queue += script(line)
    }

    func readLine(timeout: Double) async -> String? {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while queue.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    func close() { connected = false }

    /// Drop the link as if it failed.
    func fail() { connected = false }
}

/// Reply handling from the whole-code review: the CP650 echo wherever it
/// comes, which lines show the processor answering, and no reopening after
/// `disconnect()`.
@Suite struct DolbyCPReplyTests {
    /// A CP650 that answers only `KEY=?`, with a stale line ahead of the echo:
    /// the echo `mute=?` is not the reply (it parses as the pair mute, "?").
    @Test func theCP650EchoIsSkippedAfterAStaleLine() async throws {
        let transport = ScriptedTransport { line in
            line.hasSuffix("=?") ? ["fader_level=70", line, "mute=1"] : [line]   // KEY? draws only the echo
        }
        let cp = DolbyCP(transport: transport, model: .cp650, getRetries: 1, gap: 0)
        #expect(await cp.connect())
        #expect(try await cp.get("mute", timeout: 0.2) == "1")
        #expect(try await cp.get("mute", timeout: 0.2) == "1")              // now sent as mute=? at once
        await cp.disconnect()
    }

    /// Lines that do not answer the query (unsolicited, stale) do not show
    /// the processor answering: a link marked missing stays missing.
    @Test func unrelatedLinesDoNotMarkTheLinkOk() async throws {
        let transport = ScriptedTransport { line in
            line == "sys.fader ?" ? [] : ["sys.mute 0", "sys.macro_preset 3"]   // never the fader
        }
        let cp = DolbyCP(transport: transport, model: .cp850, getRetries: 0, gap: 0)
        #expect(await cp.connect())
        #expect(try await cp.get("sys.fader", timeout: 0.1) == nil)         // no reply at all
        #expect(await cp.status == .missing)
        #expect(try await cp.get("sys.ip_settings", timeout: 0.1) == nil)   // only other params
        #expect(await cp.status == .missing, "skipped lines marked the link ok")
        #expect(try await cp.get("sys.mute", timeout: 0.1) == "0")          // the real reply
        #expect(await cp.status == .ok)
        await cp.disconnect()
    }

    /// A `get` still retrying when `disconnect()` closes the link does not
    /// reopen it (the CP650 serves one client: a stray session blocks the
    /// next connect).
    @Test func aRunningGetDoesNotReopenAfterDisconnect() async throws {
        let transport = ScriptedTransport { _ in [] }                         // never answers
        let cp = DolbyCP(transport: transport, model: .cp850, pollInterval: 60,
                         autoReconnect: true, getRetries: 3, gap: 0)
        #expect(await cp.connect())
        let connects = await transport.connects
        async let held = cp.get("sys.fader", timeout: 0.15)                 // not a cancelled task
        try await Task.sleep(for: .milliseconds(50))
        await cp.disconnect()
        _ = try await held
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.connects == connects, "get reopened the link after disconnect()")
        #expect(await !cp.isLinkUp)
    }
}

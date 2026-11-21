import Foundation
import Testing
@testable import CPx50Comms

/// A CP650 link that holds the lines the unit pushed before the client
/// speaks, answers a `fader_level` query (echo first, as the CP650 does), and
/// records every line the client sends.
private actor ListenTransport: LineTransport {
    private var pending: [String]
    private(set) var sent: [String] = []
    private(set) var reads = 0
    private var connected = false

    init(pushed: [String]) { pending = pushed }

    func isConnected() -> Bool { connected }
    func peerClosed() -> Bool { false }
    func connect() async -> Bool {
        connected = true
        return true
    }
    func sendLine(_ line: String) async throws {
        sent.append(line)
        if line.hasPrefix("fader_level") { pending += [line, "fader_level=4.2"] }
    }
    func readLine(timeout: Double) async -> String? {
        reads += 1
        if !pending.isEmpty { return pending.removeFirst() }
        try? await Task.sleep(for: .seconds(min(timeout, 0.05)))
        return nil
    }
    func close() { connected = false }
}

@Suite struct DolbyCPListenTests {
    /// Lines the unit pushes on its own are applied, and nothing is sent while
    /// the link is only listened to.
    @Test func pushedLinesAreReadBeforeAnyCommandAndNothingIsSent() async throws {
        let transport = ListenTransport(pushed: ["fader_level=5.0", "mute=0"])
        let cp = DolbyCP(transport: transport, model: .cp650, gap: 0)
        await cp.setListenWindow(0.2)
        #expect(await cp.connect())
        #expect(await transport.sent.isEmpty)
        #expect(await cp.stateDict.contains { $0.param == "fader_level" })
        await cp.disconnect()
    }

    /// The listen ends at the first window in silence, and the next command
    /// goes out after it.
    @Test func listenStopsAtTheFirstQuietWindowAndTheNextCommandGoesOut() async throws {
        let transport = ListenTransport(pushed: [])
        let cp = DolbyCP(transport: transport, model: .cp650, gap: 0)
        await cp.setListenWindow(0.2)
        #expect(await cp.connect())
        #expect(await transport.reads == 1)
        #expect(await transport.sent.isEmpty)
        #expect(try await cp.get("fader_level") == "4.2")
        #expect(!(await transport.sent.isEmpty))
        await cp.disconnect()
    }

    /// Without a window, the client does not listen at all.
    @Test func noWindowMeansNoListen() async throws {
        let transport = ListenTransport(pushed: ["fader_level=9.9"])
        let cp = DolbyCP(transport: transport, model: .cp650, gap: 0)
        #expect(await cp.connect())
        #expect(await transport.reads == 0)
        #expect(await cp.stateDict.isEmpty)
        await cp.disconnect()
    }

    /// A line that does not parse is skipped, and the listen goes on.
    @Test func aLineThatDoesNotParseIsSkipped() async throws {
        let transport = ListenTransport(pushed: ["???", "mute=1"])
        let cp = DolbyCP(transport: transport, model: .cp650, gap: 0)
        await cp.setListenWindow(0.2)
        #expect(await cp.connect())
        #expect(await cp.stateDict.contains { $0.param == "mute" })
        await cp.disconnect()
    }
}

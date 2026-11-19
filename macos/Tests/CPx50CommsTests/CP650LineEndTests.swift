import Testing
@testable import CPx50Comms

/// A real CP650 answered `error` to every line that ended in LF alone
/// (report of 2026-11-19); its commands end in CR LF.
struct CP650LineEndTests {
    @Test func cp650LinesEndInCRLF() {
        #expect(WireProtocol.lineEnd(model: .cp650) == "\r\n")
    }

    @Test(arguments: [ProcessorModel.cp750, .cp850, .cp950, .cp950a])
    func otherModelsEndInLF(_ model: ProcessorModel) {
        #expect(WireProtocol.lineEnd(model: model) == "\n")
    }

    @Test func aUnitThatNeedsCRLFAnswersQueriesAndChanges() async throws {
        let sim = try await Simulator(extraArguments: ["--require-crlf", "--seed", "fader_level=63"])
        defer { sim.stop() }
        let cp = fastClient(sim.port)
        #expect(await cp.connect())
        #expect(try await cp.get("fader_level") == "63")
        #expect(try await cp.set("fader_level", 71))
        var level: String?
        for _ in 0..<20 {
            level = try await cp.get("fader_level")
            if level == "71" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(level == "71")
        await cp.disconnect()
    }

    @Test func aLineEndedInLFAloneIsAnsweredError() async throws {
        let sim = try await Simulator(extraArguments: ["--require-crlf"])
        defer { sim.stop() }
        let transport = TCPTransport(host: "127.0.0.1", port: sim.port)
        #expect(await transport.connect())
        try await transport.sendLine("fader_level?")
        #expect(await transport.readLine(timeout: 2) == "error")
        await transport.close()
    }
}

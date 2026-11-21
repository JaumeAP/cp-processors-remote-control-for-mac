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
}

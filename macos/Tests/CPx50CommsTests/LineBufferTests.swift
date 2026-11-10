import Testing
@testable import CPx50Comms

/// Text with CR, LF or a non-ASCII character is refused before anything is
/// sent. CRLF is one Swift Character, so a check made on Characters instead of
/// Unicode scalars would let it through as a second command: these cases guard
/// against that.
@Suite struct FramingRegressionTests {
    @Test(arguments: ["a\nb", "a\rb", "a\r\nb", "0\r\nMASTER=0", "fadér"])
    func refusesUnframeableText(_ bad: String) {
        #expect(throws: ProtocolError.self) {
            try WireProtocol.formatSet(model: .cp650, param: bad, value: "1")
        }
        #expect(throws: ProtocolError.self) {
            try WireProtocol.formatSet(model: .cp650, param: "mute", value: .string(bad))
        }
        #expect(throws: ProtocolError.self) { try WireProtocol.formatQuery(model: .cp650, param: bad) }
    }
}

@Suite struct LineBufferTests {
    @Test func splitsAcrossChunksAndStripsEveryTrailingCRLF() {
        var buffer = LineBuffer()
        buffer.append(Array("fader_le".utf8))
        #expect(buffer.read() == .needMore)
        buffer.append(Array("vel=70\r\r\nmute=0\n".utf8))
        #expect(buffer.read() == .done("fader_level=70"))
        #expect(buffer.read() == .done("mute=0"))
        #expect(buffer.read() == .needMore)
    }

    @Test func unterminatedTailAtEndOfStreamIsNeverALine() {
        var buffer = LineBuffer()
        buffer.append(Array("fader_level=5".utf8))
        buffer.markEOF()
        #expect(buffer.read() == .done(nil))
        #expect(buffer.isEmpty)
    }

    @Test func newlineBeyondTheLimitDiscardsThroughIt() {
        var buffer = LineBuffer(limit: 8)
        buffer.append(Array("0123456789abcdef\nmute=1\n".utf8))
        #expect(buffer.read() == .done(nil))
        #expect(buffer.read() == .done("mute=1"))
    }

    @Test func overlongUnterminatedLineIsDroppedWithItsRest() {
        var buffer = LineBuffer(limit: 8)
        buffer.append(Array("0123456789".utf8))
        #expect(buffer.read() == .done(nil))
        buffer.append(Array("tail\nmute=1\n".utf8))   // the rest of the cut line
        #expect(buffer.read() == .done("mute=1"))
    }

    @Test func nonASCIIBytesDecodeToReplacement() {
        var buffer = LineBuffer()
        buffer.append([0x61, 0xFF, 0x0A])
        #expect(buffer.read() == .done("a\u{FFFD}"))
    }
}

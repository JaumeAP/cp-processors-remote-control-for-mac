// Fuzz tests: thousands of random inputs, from a fixed seed so a failure
// repeats exactly, against the line reader and the wire protocol. Each test
// checks rules that must hold for every input, not a single expected value.

import Testing
@testable import CPx50Comms

/// A seeded generator.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random bytes biased towards the ones the reader treats specially.
private func randomBytes(_ count: Int, _ rng: inout SplitMix64) -> [UInt8] {
    (0..<count).map { _ in
        switch Int.random(in: 0..<10, using: &rng) {
        case 0: 0x0A                                        // LF
        case 1: 0x0D                                        // CR
        case 2: UInt8.random(in: 0x80...0xFF, using: &rng)  // not ASCII
        case 3: UInt8.random(in: 0x00...0x1F, using: &rng)  // control
        default: UInt8.random(in: 0x20...0x7E, using: &rng) // printable
        }
    }
}

/// Random text mixing ASCII, controls, CR/LF and non-ASCII characters.
private func randomText(_ rng: inout SplitMix64, maxLength: Int = 24) -> String {
    let pool: [Character] = Array("abcxyz_.=? 019") + ["\n", "\r", "\r\n", "\t", "\u{0}", "é", "€", "\u{212A}", "😀"]
    return String((0..<Int.random(in: 0...maxLength, using: &rng)).map { _ in pool.randomElement(using: &rng)! })
}

@Suite struct LineBufferFuzzTests {
    /// Random bytes in random chunks, with a small limit so over-long lines
    /// happen often: the reader never crashes, never hangs, and every line it
    /// returns has no LF, no trailing CR, and only ASCII or U+FFFD.
    @Test func randomStreamsKeepTheLineRules() {
        var rng = SplitMix64(state: 2026)
        for _ in 0..<3000 {
            var buffer = LineBuffer(limit: Int.random(in: 1...64, using: &rng))
            let stream = randomBytes(Int.random(in: 0...600, using: &rng), &rng)
            var offset = 0
            var reads = 0
            while true {
                if offset < stream.count {
                    let size = Int.random(in: 1...40, using: &rng)
                    buffer.append(stream[offset..<min(offset + size, stream.count)])
                    offset += size
                } else if !buffer.atEOF {
                    buffer.markEOF()
                }
                var done = false
                while case .done(let line) = buffer.read() {
                    reads += 1
                    if let line {
                        #expect(!line.contains("\n"))
                        #expect(!line.hasSuffix("\r"))
                        #expect(line.unicodeScalars.allSatisfy { $0.isASCII || $0 == "\u{FFFD}" })
                    }
                    if buffer.atEOF && buffer.isEmpty { done = true; break }
                    #expect(reads < 10_000, "the reader must not loop")
                    if reads >= 10_000 { return }
                }
                if done || (buffer.atEOF && buffer.isEmpty) { break }
            }
        }
    }

    /// When every line is shorter than the limit and newline-terminated, the
    /// reader gives exactly the lines a plain split would, whatever the chunks.
    @Test func shortLinesMatchAPlainSplit() {
        var rng = SplitMix64(state: 650)
        for _ in 0..<2000 {
            let lines = (0..<Int.random(in: 0...12, using: &rng)).map { _ in
                randomBytes(Int.random(in: 0...30, using: &rng), &rng).filter { $0 != 0x0A }
            }
            let stream: [UInt8] = lines.flatMap { $0 + [UInt8(0x0A)] }
            var buffer = LineBuffer(limit: 64)
            var offset = 0
            var got: [String] = []
            while offset < stream.count {
                let size = Int.random(in: 1...16, using: &rng)
                buffer.append(stream[offset..<min(offset + size, stream.count)])
                offset += size
                while case .done(let line) = buffer.read() { if let line { got.append(line) } }
            }
            #expect(got == lines.map { LineBuffer.decode($0 + [UInt8(0x0A)]) })
        }
    }
}

@Suite struct WireProtocolFuzzTests {
    /// Every random param and value either is refused with a ProtocolError,
    /// or gives one ASCII line with no CR or LF: never a second command.
    @Test(arguments: ProcessorModel.allCases)
    func framingNeverLetsANewlineThrough(_ model: ProcessorModel) {
        var rng = SplitMix64(state: model.rawValue.utf8.reduce(0) { $0 &* 31 &+ UInt64($1) })
        for _ in 0..<3000 {
            let param = randomText(&rng)
            let value = randomText(&rng)
            for line in [try? WireProtocol.formatSet(model: model, param: param, value: .string(value)),
                         try? WireProtocol.formatQuery(model: model, param: param)] {
                guard let line else { continue }
                #expect(!line.unicodeScalars.contains { $0 == "\n" || $0 == "\r" })
                #expect(line.unicodeScalars.allSatisfy { $0.isASCII })
            }
        }
    }

    /// A simple param and value survive a SET and a reply unchanged.
    @Test(arguments: ProcessorModel.allCases)
    func simpleSetsRoundTrip(_ model: ProcessorModel) throws {
        var rng = SplitMix64(state: 70)
        let letters = Array("abcdefghijklmnopqrstuvwxyz_.")
        for _ in 0..<1000 {
            let param = String((0..<Int.random(in: 1...20, using: &rng)).map { _ in letters.randomElement(using: &rng)! })
            let value = String(Int.random(in: 0...100, using: &rng))
            let line = try WireProtocol.formatSet(model: model, param: param, value: .string(value))
            let pairs = WireProtocol.parseResponse(model: model, text: line)
            #expect(pairs == [ResponsePair(param: param, value: value)])
        }
    }

    /// Random reply text never crashes the parser, and no pair it returns
    /// carries a CR or LF.
    @Test(arguments: ProcessorModel.allCases)
    func randomRepliesParseSafely(_ model: ProcessorModel) {
        var rng = SplitMix64(state: 99)
        for _ in 0..<3000 {
            let text = (0..<Int.random(in: 0...5, using: &rng)).map { _ in randomText(&rng, maxLength: 40) }
                .joined(separator: "\n")
            for pair in WireProtocol.parseResponse(model: model, text: text) {
                #expect(!pair.param.unicodeScalars.contains { $0 == "\n" || $0 == "\r" })
                #expect(!pair.value.unicodeScalars.contains { $0 == "\n" || $0 == "\r" })
            }
        }
    }
}

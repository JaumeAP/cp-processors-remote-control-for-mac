/// client reads it: asyncio's `StreamReader.readline()` with its 64 KiB
///
/// 1. Lines are cut when they are read, not when bytes arrive.
/// 2. A newline found beyond the limit: everything through it is discarded
/// 3. More than the limit buffered with no newline: the buffer is discarded
///    and the read yields nothing; the rest of that line, up to and including
///    rest as a line; the maintainer chose to drop it, so a fragment of a cut
///    line never becomes a reply (accepted difference, 2026-11-09).
/// 4. At end of stream, an unterminated tail is consumed and yields nothing
///    (the cut point is unknown: `fader_level=5` could be `fader_level=50`).
/// 5. A line is decoded as ASCII with U+FFFD for any byte above 0x7F, and
///    every trailing CR and LF is stripped (`rstrip("\r\n")`).
struct LineBuffer {
    static let defaultLimit = 64 * 1024

    enum Read: Equatable {
        /// A complete line, or nil for a line that is never a reply.
        case done(String?)
        /// Not enough bytes yet: wait for more.
        case needMore
    }

    let limit: Int
    private var bytes: [UInt8] = []
    private var discardingRest = false
    private(set) var atEOF = false

    init(limit: Int = LineBuffer.defaultLimit) {
        self.limit = limit
    }

    var isEmpty: Bool { bytes.isEmpty }

    mutating func append<S: Sequence>(_ data: S) where S.Element == UInt8 {
        bytes.append(contentsOf: data)
    }

    mutating func markEOF() {
        atEOF = true
    }

    /// One `readline()` attempt over what is buffered.
    mutating func read() -> Read {
        if discardingRest {
            guard let newline = bytes.firstIndex(of: 0x0A) else {
                bytes.removeAll(keepingCapacity: true)
                return atEOF ? .done(nil) : .needMore
            }
            bytes.removeSubrange(...newline)
            discardingRest = false
        }
        if let newline = bytes.firstIndex(of: 0x0A) {
            if newline > limit {
                bytes.removeSubrange(...newline)
                return .done(nil)
            }
            let line = Array(bytes[...newline])
            bytes.removeSubrange(...newline)
            return .done(Self.decode(line))
        }
        if bytes.count > limit {
            bytes.removeAll(keepingCapacity: true)
            discardingRest = true
            return .done(nil)
        }
        if atEOF {
            bytes.removeAll()   // empty: end of stream; otherwise an unterminated tail
            return .done(nil)
        }
        return .needMore
    }

    /// ASCII with U+FFFD for bytes above 0x7F, trailing CR and LF stripped.
    static func decode(_ raw: [UInt8]) -> String {
        var end = raw.endIndex
        while end > raw.startIndex, raw[end - 1] == 0x0A || raw[end - 1] == 0x0D { end -= 1 }
        var scalars = String.UnicodeScalarView()
        for byte in raw[..<end] {
            scalars.append(byte < 0x80 ? Unicode.Scalar(byte) : "\u{FFFD}")
        }
        return String(scalars)
    }
}

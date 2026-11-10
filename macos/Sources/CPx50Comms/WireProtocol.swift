/// A value to SET.
public enum WireValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)

    /// Exact identity: strings compare by Unicode scalars, not by canonical
    /// equivalence.
    func isIdentical(to other: WireValue) -> Bool {
        switch (self, other) {
        case let (.bool(a), .bool(b)): a == b
        case let (.int(a), .int(b)): a == b
        case let (.string(a), .string(b)): sameScalars(a, b)
        default: false
        }
    }
}

/// Literals: `70` is `.int`, `true` is `.bool`, `"x"` is `.string`.
extension WireValue: ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByStringLiteral
{
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(stringLiteral value: String) { self = .string(value) }
}

/// One `(param, value)` pair parsed from a reply line.
public struct ResponsePair: Sendable, Equatable {
    public let param: String
    public let value: String

    public init(param: String, value: String) {
        self.param = param
        self.value = value
    }
}

public enum ProtocolError: Error, Equatable {
    case newlineOrCR(field: Field)
    case nonASCII(field: Field)

    public enum Field: Sendable {
        case param, value
    }
}

/// Per-model formatting and parsing of wire lines. Stateless.
///
/// 1. SET: `param=value` (CP650) or `param value` (the others).
/// 2. Query: `param?` (CP650) or `param ?` (the others).
/// 3. Replies are split into lines and `(param, value)` pairs.
/// 4. Only CR, LF and non-ASCII are refused; spaces, `=`, `?` and other
///    control bytes pass.
public enum WireProtocol {
    /// The SET line, without the trailing newline. The param is checked
    /// before the value, and within each, CR/LF before non-ASCII.
    public static func formatSet(model: ProcessorModel, param: String, value: WireValue)
        throws(ProtocolError) -> String
    {
        let text = wireText(value)
        try requireFramable(param, .param)
        try requireFramable(text, .value)
        switch model.dialect {
        case .keyValue: return "\(param)=\(text)"
        case .paramValue: return "\(param) \(text)"
        }
    }

    /// The query line, without the trailing newline.
    public static func formatQuery(model: ProcessorModel, param: String) throws(ProtocolError) -> String {
        try requireFramable(param, .param)
        switch model.dialect {
        case .keyValue: return "\(param)=?"
        case .paramValue: return "\(param) ?"
        }
    }

    /// Every pair in a reply. Blank lines and lines without a separator are
    /// skipped. A CP650 line splits at its first `=` (an empty param is kept);
    /// the others split at the first run of whitespace.
    public static func parseResponse(model: ProcessorModel, text: String) -> [ResponsePair] {
        splitLines(Array(text.unicodeScalars)).compactMap { raw in
            let line = strip(raw[...])
            guard !line.isEmpty else { return nil }
            switch model.dialect {
            case .keyValue:
                guard let eq = line.firstIndex(of: "=") else { return nil }
                return ResponsePair(param: string(strip(line[..<eq])),
                                    value: string(strip(line[(eq + 1)...])))
            case .paramValue:
                guard let gap = line.firstIndex(where: isWhitespaceScalar) else { return nil }
                let rest = line[gap...].drop(while: isWhitespaceScalar)
                guard !rest.isEmpty else { return nil }
                return ResponsePair(param: string(line[..<gap]), value: string(strip(rest)))
            }
        }
    }

    /// The wire text of a value: booleans as `1`/`0`, integers in decimal,
    /// strings as they are.
    public static func wireText(_ value: WireValue) -> String {
        switch value {
        case .bool(let b): return b ? "1" : "0"
        case .int(let i): return String(i)
        case .string(let s): return s
        }
    }

    // MARK: - Framing checks

    private static func requireFramable(_ s: String, _ field: ProtocolError.Field) throws(ProtocolError) {
        let scalars = s.unicodeScalars
        if scalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
            throw .newlineOrCR(field: field)
        }
        if !scalars.allSatisfy(\.isASCII) {
            throw .nonASCII(field: field)
        }
    }


    private typealias Scalars = ArraySlice<Unicode.Scalar>

    /// Splits text into lines: breaks on LF, CR, CRLF, VT, FF, FS, GS, RS, NEL,
    /// LINE SEPARATOR and PARAGRAPH SEPARATOR; no trailing empty line.
    private static func splitLines(_ s: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var lines: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            if isLineBreak(c) {
                lines.append(current)
                current = []
                if c == "\r", i + 1 < s.count, s[i + 1] == "\n" { i += 1 }
            } else {
                current.append(c)
            }
            i += 1
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func isLineBreak(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// The whitespace that is stripped and that separates param and value. Not
    /// the same set as Swift's `Character.isWhitespace` (it includes
    /// U+001C...U+001F).
    private static func isWhitespaceScalar(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    static func pythonStripped(_ s: String) -> String {
        string(strip(Array(s.unicodeScalars)[...]))
    }

    /// Strips leading and trailing whitespace. Keeps the slice's indices.
    private static func strip(_ s: Scalars) -> Scalars {
        var lo = s.startIndex
        var hi = s.endIndex
        while lo < hi, isWhitespaceScalar(s[lo]) { lo += 1 }
        while hi > lo, isWhitespaceScalar(s[hi - 1]) { hi -= 1 }
        return s[lo..<hi]
    }

    private static func string(_ s: Scalars) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s)
        return String(out)
    }
}

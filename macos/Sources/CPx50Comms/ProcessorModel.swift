/// The Dolby cinema processors the control channel speaks to, and how each
/// one is reached: its TCP port and its command framing. Port 61408 and the
/// `param value` framing are those of the CP750 and CP950 manuals; port 61412
/// and `KEY=VALUE` are the CP650's.
public enum ProcessorModel: String, CaseIterable, Sendable {
    case cp650 = "CP650"
    case cp750 = "CP750"
    case cp850 = "CP850"
    case cp950 = "CP950"
    case cp950a = "CP950A"

    /// How commands and replies are framed on the wire.
    public enum Dialect: Sendable {
        /// `KEY=VALUE`, query `KEY?` (CP650).
        case keyValue
        /// `param value`, query `param ?` (CP750, CP850, CP950, CP950A).
        case paramValue
    }

    /// The model named exactly `name`. The match is case-sensitive and
    /// compares Unicode scalars, so `"cp650"`, `" CP650"` or a fullwidth
    /// `"ＣＰ６５０"` are unknown.
    public init(name: String) throws(UnknownModelError) {
        guard let model = Self.allCases.first(where: {
            $0.rawValue.unicodeScalars.elementsEqual(name.unicodeScalars)
        }) else {
            throw UnknownModelError(name: name)
        }
        self = model
    }

    /// The TCP port of the model's control channel.
    public var defaultPort: UInt16 {
        switch self {
        case .cp650: 61412
        case .cp750, .cp850, .cp950, .cp950a: 61408
        }
    }

    /// The model's command framing. An exhaustive switch, so a new model
    /// cannot fall into a framing by accident.
    public var dialect: Dialect {
        switch self {
        case .cp650: .keyValue
        case .cp750, .cp850, .cp950, .cp950a: .paramValue
        }
    }
}

/// A model name that matches no `ProcessorModel` exactly.
public struct UnknownModelError: Error, Equatable {
    public let name: String
}

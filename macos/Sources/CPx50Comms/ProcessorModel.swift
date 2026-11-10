/// The Dolby cinema processors the control channel speaks to, and the
///
/// Port 61408 and the `sys.*` format are confirmed by the CP950 manual;
/// `maxConnections` and the CP950A SOAP version `"2.0"` are labels kept from
/// the internal spec, unverified (the maintainer confirmed carrying them).
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

    /// The model named exactly `name`: case-sensitive, compared on Unicode
    /// or a fullwidth `"ＣＰ６５０"` are unknown).
    public init(name: String) throws(UnknownModelError) {
        guard let model = Self.allCases.first(where: {
            $0.rawValue.unicodeScalars.elementsEqual(name.unicodeScalars)
        }) else {
            throw UnknownModelError(name: name)
        }
        self = model
    }

    public var defaultPort: UInt16 {
        switch self {
        case .cp650: 61412
        case .cp750, .cp850, .cp950, .cp950a: 61408
        }
    }

    /// `"KEY=VALUE"` (CP650) or the dotted parameter namespace.
    public var namespace: String {
        switch self {
        case .cp650: "KEY=VALUE"
        case .cp750: "cp750.*"
        case .cp850, .cp950, .cp950a: "sys.*"
        }
    }

    public var maxConnections: Int {
        switch self {
        case .cp650: 1
        case .cp750, .cp850, .cp950, .cp950a: 20
        }
    }

    /// The web-services version; nil for the CP650, which has none.
    public var soapVersion: String? {
        switch self {
        case .cp650: nil
        case .cp750, .cp850, .cp950: "1.1"
        case .cp950a: "2.0"
        }
    }

    /// An exhaustive switch, so a new model cannot fall into a framing by
    /// accident; the fixture pins that it agrees with `namespace`.
    public var dialect: Dialect {
        switch self {
        case .cp650: .keyValue
        case .cp750, .cp850, .cp950, .cp950a: .paramValue
        }
    }

    public var usesKeyValue: Bool { dialect == .keyValue }
}

/// A model name that matches no `ProcessorModel` exactly.
public struct UnknownModelError: Error, Equatable {
    public let name: String
}

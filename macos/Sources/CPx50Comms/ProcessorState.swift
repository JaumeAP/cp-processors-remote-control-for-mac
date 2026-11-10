/// FAULT, which nothing ever sets; the maintainer confirmed only these three
/// are needed.
public enum ProcessorStatus: Sendable, Equatable {
    /// Never connected yet.
    case initializing
    /// The last exchange got a real reply (a `KEY=VALUE` line or `ACK`).
    case ok
    /// The link is down, a command drew no reply at all, or the watchdog saw
    /// no successful exchange in time.
    case missing
}

/// The processor's status and the last known value of each parameter
/// record: the client drives every change.
///
/// key is set again, and a value may change type. Params are keyed by Unicode
public struct ProcessorState: Sendable {
    public private(set) var status: ProcessorStatus = .initializing
    private var entries: [(param: String, value: WireValue)] = []
    private var positions: [ScalarKey: Int] = [:]

    public init() {}

    public mutating func mark(_ status: ProcessorStatus) {
        self.status = status
    }

    public mutating func set(_ param: String, _ value: WireValue) {
        let key = ScalarKey(param)
        if let position = positions[key] {
            entries[position].value = value
        } else {
            positions[key] = entries.count
            entries.append((param, value))
        }
    }

    public func value(of param: String) -> WireValue? {
        positions[ScalarKey(param)].map { entries[$0].value }
    }

    public func value(of param: String, default fallback: WireValue) -> WireValue {
        value(of: param) ?? fallback
    }

    public var values: [(param: String, value: WireValue)] { entries }
}

/// A dictionary key that compares strings by Unicode scalars, not by Swift's
/// canonical equivalence.
struct ScalarKey: Hashable, Sendable {
    let scalars: [UInt32]

    init(_ s: String) {
        scalars = s.unicodeScalars.map(\.value)
    }
}

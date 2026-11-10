public enum ProtocolTiming {
    /// Minimum gap between sent commands on the CP650, whose hardware needs
    /// more headroom than the general case ("Known Issues": 250 ms).
    public static let cp650Gap: Double = 0.25
    /// Minimum gap between sent commands on every other model.
    public static let defaultGap: Double = 0.10
    /// How long a query waits for its reply.
    public static let queryTimeout: Double = 1.5
    /// Without a real reply for this long, an actively polled processor is MISSING.
    public static let watchdog: Double = 3.0
    /// Default seconds between watchdog ticks.
    public static let defaultPollInterval: Double = 1.0
    /// Longest a send may wait on a peer that is not reading.
    public static let writeTimeout: Double = 2.0
    /// Longest closing a link may take.
    public static let closeTimeout: Double = 1.0

    /// CP650 gap only for exactly `"CP650"` (Unicode scalars, case-sensitive),
    /// the default gap for any other name, unknown names included, with no
    /// error (confirmed by the maintainer).
    public static func gap(forModelNamed name: String) -> Double {
        name.unicodeScalars.elementsEqual(ProcessorModel.cp650.rawValue.unicodeScalars)
            ? cp650Gap : defaultGap
    }
}

extension ProcessorModel {
    /// Minimum gap between two commands sent to this model.
    public var commandGap: Double {
        switch self {
        case .cp650: ProtocolTiming.cp650Gap
        case .cp750, .cp850, .cp950, .cp950a: ProtocolTiming.defaultGap
        }
    }
}

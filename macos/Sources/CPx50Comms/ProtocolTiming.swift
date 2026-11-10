/// The timing of the control channel: gaps between commands and timeouts,
/// in seconds.
public enum ProtocolTiming {
    /// Minimum gap between sent commands on the CP650, which needs more
    /// headroom than the other models (250 ms).
    public static let cp650Gap: Double = 0.25
    /// Minimum gap between sent commands on every other model.
    public static let defaultGap: Double = 0.10
    /// How long a query waits for its reply.
    public static let queryTimeout: Double = 1.5
    /// Without a real reply for this long, an actively polled processor is
    /// marked missing.
    public static let watchdog: Double = 3.0
    /// Default seconds between watchdog ticks.
    public static let defaultPollInterval: Double = 1.0
    /// Longest a send may wait on a peer that is not reading.
    public static let writeTimeout: Double = 2.0
    /// Longest closing a link may take.
    public static let closeTimeout: Double = 1.0
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

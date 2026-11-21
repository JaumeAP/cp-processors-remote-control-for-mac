/// The Dolby cinema processors CP Remote draws a front panel for, and the TCP
/// port each one's control channel uses (61412 for the CP650, 61408 for the
/// others), shown in Setup.
enum ProcessorModel: String, Sendable {
    case cp650 = "CP650"
    case cp750 = "CP750"
    case cp850 = "CP850"
    case cp950 = "CP950"
    case cp950a = "CP950A"

    /// The TCP port of the model's control channel.
    var defaultPort: UInt16 {
        switch self {
        case .cp650: 61412
        case .cp750, .cp850, .cp950, .cp950a: 61408
        }
    }
}

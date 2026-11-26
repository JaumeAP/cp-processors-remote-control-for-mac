// Monotonic time that runs on macOS 11. `ContinuousClock` and `Duration` need
// macOS 13, so the app keeps its instants as nanoseconds from the system's
// uptime clock and its intervals as seconds.

import Foundation

enum Monotonic {
    /// A point on the monotonic clock; it never goes back.
    struct Instant: Comparable, Sendable {
        let nanoseconds: UInt64

        static var now: Instant {
            Instant(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.nanoseconds < rhs.nanoseconds
        }

        /// The instant `seconds` later (`seconds` may be negative).
        static func + (lhs: Instant, seconds: TimeInterval) -> Instant {
            Instant(nanoseconds: lhs.nanoseconds &+ UInt64(bitPattern: Int64(seconds * 1e9)))
        }

        /// The instant `seconds` earlier.
        static func - (lhs: Instant, seconds: TimeInterval) -> Instant {
            lhs + -seconds
        }

        /// The seconds from `rhs` to `lhs` (negative when `lhs` is earlier).
        static func - (lhs: Instant, rhs: Instant) -> TimeInterval {
            Double(Int64(bitPattern: lhs.nanoseconds &- rhs.nanoseconds)) / 1e9
        }
    }

    /// Suspend the task for `seconds`; returns at once for zero or less.
    static func sleep(for seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }
}

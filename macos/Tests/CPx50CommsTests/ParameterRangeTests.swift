import Foundation
import Testing
@testable import CPx50Comms

/// Public times and counts that used to trap (Duration.seconds on an
/// infinite or huge value, a Range with a negative bound) are made safe.
@Suite struct ParameterRangeTests {
    @Test func timesAreClamped() {
        #expect(ProtocolTiming.clamped(.infinity) == ProtocolTiming.longestWait)
        #expect(ProtocolTiming.clamped(1e30) == ProtocolTiming.longestWait)
        #expect(ProtocolTiming.clamped(-5) == 0)
        #expect(ProtocolTiming.clamped(.nan) == 0)
        #expect(ProtocolTiming.clamped(-.infinity, floor: 0.01) == 0.01)
        #expect(ProtocolTiming.clamped(1.5) == 1.5)
        #expect(ProtocolTiming.clampedRetries(-2) == 0)
        #expect(ProtocolTiming.clampedRetries(.max) == 100)
    }
}

import Foundation
import Testing
@testable import CPx50Comms

// Tests that kill the mutants the first mutation run (macos/scripts/mutate.py)
// left alive in the framing, queue and wire code: boundaries, equality and
// line breaks the other tests did not pin down.

/// The 64 KiB line limit is `limit` bytes of line, newline excluded.
@Suite struct LineBufferBoundaryTests {
    private func buffer(_ text: String) -> LineBuffer {
        var buffer = LineBuffer(limit: 8)
        buffer.append(Array(text.utf8))
        return buffer
    }

    @Test func aLineOfExactlyTheLimitIsKept() {
        var b = buffer("01234567\n")
        #expect(b.read() == .done("01234567"))
    }

    @Test func aLineOneByteOverTheLimitIsDropped() {
        var b = buffer("012345678\n")
        #expect(b.read() == .done(nil))
    }

    @Test func exactlyTheLimitWithoutANewlineWaitsForMore() {
        var b = buffer("01234567")
        #expect(b.read() == .needMore)
        b.append(Array("\n".utf8))
        #expect(b.read() == .done("01234567"))
    }

    @Test func oneByteOverTheLimitWithoutANewlineIsDroppedAtOnce() {
        var b = buffer("012345678")
        #expect(b.read() == .done(nil))
    }

    /// After the rest of a cut line is thrown away, every later line is read,
    /// not only the first.
    @Test func afterACutLineEveryFollowingLineIsRead() {
        var b = buffer("0123456789")
        #expect(b.read() == .done(nil))
        b.append(Array("tail\nmute=1\nmute=2\n".utf8))
        #expect(b.read() == .done("mute=1"))
        #expect(b.read() == .done("mute=2"))
        #expect(b.read() == .needMore)
    }
}

@Suite struct CommandQueueBoundaryTests {
    private func set(_ param: String, _ value: String) -> PendingSet {
        PendingSet(param: param, value: .string(value))
    }

    /// Putting one back into a queue that has room for it drops nothing.
    @Test func requeueFrontKeepsAQueueThatJustFits() {
        var queue = CommandQueue(maxSize: 2)
        queue.enqueue(set("a", "1"))
        queue.requeueFront(set("b", "1"))
        #expect(queue.items.map(\.param) == ["b", "a"])
    }
}

/// `PendingSet` equality is exact: param, value and timeout all count, and
/// strings compare by Unicode scalars.
@Suite struct PendingSetEqualityTests {
    private func pending(_ param: String = "p", _ value: WireValue = .string("1"),
                         _ timeout: Double = 0.5) -> PendingSet {
        PendingSet(param: param, value: value, timeout: timeout)
    }

    @Test func equalWhenParamValueAndTimeoutAreEqual() {
        #expect(pending() == pending())
    }

    @Test func aDifferentValueIsNotEqual() {
        #expect(pending("p", .string("1"), 0.5) != pending("p", .string("2"), 0.5))
        #expect(pending("p", .string("1"), 0.5) != pending("p", .string("2"), 0.7))
    }

    @Test func aDifferentTimeoutIsNotEqual() {
        #expect(pending("p", .string("1"), 0.5) != pending("p", .string("1"), 0.7))
    }

    @Test func aDifferentParamIsNotEqual() {
        #expect(pending("p", .string("1"), 0.5) != pending("q", .string("1"), 0.5))
    }

    @Test func canonicallyEquivalentParamsAreNotEqual() {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        #expect(composed == decomposed)   // Swift's own comparison says equal
        #expect(pending(composed) != pending(decomposed))
    }
}

@Suite struct WireValueIdentityTests {
    @Test func aValueIsIdenticalOnlyToTheSameValueOfTheSameKind() {
        #expect(WireValue.bool(true).isIdentical(to: .bool(true)))
        #expect(!WireValue.bool(true).isIdentical(to: .bool(false)))
        #expect(WireValue.int(7).isIdentical(to: .int(7)))
        #expect(!WireValue.int(7).isIdentical(to: .int(8)))
        #expect(WireValue.string("a").isIdentical(to: .string("a")))
        #expect(!WireValue.string("a").isIdentical(to: .string("b")))
        #expect(!WireValue.int(1).isIdentical(to: .bool(true)))
        #expect(!WireValue.string("1").isIdentical(to: .int(1)))
    }
}

/// A reply may end its lines with CR alone, with CR LF, or with LF.
@Suite struct ReplyLineBreakTests {
    @Test func aLoneCRSeparatesTheLinesOfAReply() {
        let keyValue = WireProtocol.parseResponse(model: .cp650, text: "fader_level=70\rmute=1")
        #expect(keyValue.map(\.param) == ["fader_level", "mute"])
        #expect(keyValue.map(\.value) == ["70", "1"])
        let paramValue = WireProtocol.parseResponse(model: .cp850, text: "fader_level 70\rmute 1")
        #expect(paramValue.map(\.param) == ["fader_level", "mute"])
        #expect(paramValue.map(\.value) == ["70", "1"])
    }

    @Test func crLfIsOneBreakAndLfAloneIsOne() {
        for text in ["fader_level=70\r\nmute=1\r\n", "fader_level=70\nmute=1\n"] {
            let pairs = WireProtocol.parseResponse(model: .cp650, text: text)
            #expect(pairs.map(\.param) == ["fader_level", "mute"], "\(text.debugDescription)")
            #expect(pairs.map(\.value) == ["70", "1"], "\(text.debugDescription)")
        }
    }
}

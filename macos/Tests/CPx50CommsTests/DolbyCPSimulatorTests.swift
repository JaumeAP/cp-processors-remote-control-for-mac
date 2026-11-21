import Foundation
import Testing
@testable import CPx50Comms

/// A CP650 client with short timings: 50 ms gap, 0.1 s watchdog ticks, 0.6 s
/// watchdog, backoff 0.05 to 0.2 s.
func fastClient(_ port: UInt16, autoReconnect: Bool = false, pollParam: String? = nil,
                pollInterval: Double = 0.1, getRetries: Int = 2) -> DolbyCP {
    DolbyCP(host: "127.0.0.1", port: port, model: .cp650, pollInterval: pollInterval,
            pollParam: pollParam, watchdog: 0.6, autoReconnect: autoReconnect,
            reconnectBackoff: (0.05, 0.2), getRetries: getRetries, gap: 0.05)
}

/// Poll `condition` every 50 ms for up to `seconds`; its last value.
func eventually(_ seconds: Double = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

@Suite struct CommandQueueTests {
    func set(_ param: String, _ value: String) -> PendingSet { PendingSet(param: param, value: .string(value)) }

    @Test func coalescesInPlaceKeepingPosition() {
        var queue = CommandQueue()
        queue.enqueue(set("a", "1"))
        queue.enqueue(set("b", "1"))
        queue.enqueue(set("a", "2"))
        #expect(queue.items == [set("a", "2"), set("b", "1")])
    }

    @Test func overflowDropsTheOldest() {
        var queue = CommandQueue(maxSize: 3)
        for name in ["a", "b", "c", "d"] { queue.enqueue(set(name, "1")) }
        #expect(queue.items.map(\.param) == ["b", "c", "d"])
        queue.enqueue(set("b", "2"))   // coalescing does not grow or drop
        #expect(queue.items == [set("b", "2"), set("c", "1"), set("d", "1")])
    }

    @Test func requeueFrontNeverResurrectsAnOlderValue() {
        var queue = CommandQueue()
        queue.enqueue(set("a", "new"))
        queue.requeueFront(set("a", "old"))
        #expect(queue.items == [set("a", "new")])
        queue.requeueFront(set("b", "1"))
        #expect(queue.items == [set("b", "1"), set("a", "new")])
    }

    @Test func requeueFrontOverCapacityDropsTheNewestTail() {
        var queue = CommandQueue(maxSize: 2)
        queue.enqueue(set("a", "1"))
        queue.enqueue(set("b", "1"))
        queue.requeueFront(set("c", "1"))
        #expect(queue.items.map(\.param) == ["c", "a"])
        #expect(queue.dequeue() == set("c", "1"))
        #expect(queue.count == 1)
    }
}

@Suite struct DolbyCPConnectFailureTests {
    @Test func refusedConnectionReturnsFalse() async {
        // Port 1 on loopback has no listener.
        let cp = fastClient(1)
        #expect(await cp.connect() == false)
        #expect(await cp.status == .missing)
        #expect(await !cp.isLinkUp)
    }

    @Test func getWithoutALinkReturnsNil() async throws {
        let cp = DolbyCP(host: "127.0.0.1", model: .cp650)
        #expect(try await cp.get("mute") == nil)
        #expect(await cp.status == .missing)
    }
}

import Foundation
import Testing
@testable import CPx50Comms

/// The C++ fake processor: `$CPSIM_BIN`. Tests skip when it is absent.
let simulatorPath: String? = {
    guard let env = ProcessInfo.processInfo.environment["CPSIM_BIN"], !env.isEmpty else { return nil }
    return FileManager.default.isExecutableFile(atPath: env) ? env : nil
}()

/// A value behind a lock, shared with a pipe's readability handler.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// Stop a simulator: SIGINT, then wait at most 5 s, then SIGKILL. Never
/// `waitUntilExit()`: it was seen blocking forever after the simulator had
/// exited (a sampled hang of the whole suite, 2026-11-09).
func stopSimulatorProcess(_ process: Process) {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    process.interrupt()
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < deadline { usleep(10_000) }
    if process.isRunning { kill(pid, SIGKILL) }
}

/// One `processor_sim --model CP650 --profile` on loopback: a free port by
/// default, or `port` (to bring a simulator back on the same address).
final class Simulator: @unchecked Sendable {
    let process = Process()
    let port: UInt16
    private let log = Locked(Data())

    init(port requested: UInt16 = 0, extraArguments: [String] = []) async throws {
        let path = try #require(simulatorPath)
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--model", "CP650", "--host", "127.0.0.1", "--port", String(requested),
                             "--profile"] + extraArguments
        let out = Pipe()
        process.standardOutput = out
        let err = Pipe()
        process.standardError = err
        err.fileHandleForReading.readabilityHandler = { [log] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil   // end of stream: stop the handler from spinning
                return
            }
            log.withLock { $0.append(chunk) }
        }
        try process.run()
        var found: UInt16?
        for try await line in out.fileHandleForReading.bytes.lines {
            if let colon = line.lastIndex(of: ":"),
               let p = UInt16(line[line.index(after: colon)...].prefix { $0.isNumber }) {
                found = p
            }
            break
        }
        port = try #require(found)
    }

    func stop() {
        stopSimulatorProcess(process)
    }

    /// Lines the simulator received, from its `--log` output on stderr
    /// (`[+   0.456s] recv: fader_level=5`).
    func received() -> [String] {
        let text = log.withLock { String(decoding: $0, as: UTF8.self) }
        return text.split(separator: "\n").compactMap { line in
            line.range(of: "recv: ").map { String(line[$0.upperBound...]) }
        }
    }

    /// Close every live TCP link while the simulator keeps listening.
    func dropConnections() {
        kill(process.processIdentifier, SIGUSR1)
    }

    deinit { stop() }
}

/// A CP650 client on the simulator with short timings: 50 ms gap, 0.1 s
/// watchdog ticks, 0.6 s watchdog, backoff 0.05 to 0.2 s.
func fastClient(_ port: UInt16, autoReconnect: Bool = false, pollParam: String? = nil,
                pollInterval: Double = 0.1, getRetries: Int = 2) -> DolbyCP {
    DolbyCP(host: "127.0.0.1", port: port, model: .cp650, pollInterval: pollInterval,
            pollParam: pollParam, watchdog: 0.6, autoReconnect: autoReconnect,
            reconnectBackoff: (0.05, 0.2), getRetries: getRetries, gap: 0.05)
}

/// The wire text of the last-known value of `param`, if any.
func known(_ cp: DolbyCP, _ param: String) async -> String? {
    await cp.stateDict.first { sameScalars($0.param, param) }.map { WireProtocol.wireText($0.value) }
}

func isUpAndOk(_ cp: DolbyCP) async -> Bool {
    let up = await cp.isLinkUp
    let status = await cp.status
    return up && status == .ok
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

@Suite(.serialized, .enabled(if: simulatorPath != nil, "needs CPSIM_BIN (the simulator)"))
struct DolbyCPLinkTests {
    @Test func readsASeededValue() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port)
        #expect(await cp.connect())
        #expect(await cp.isLinkUp)
        #expect(try await cp.get("fader_level", timeout: 0.5) == "70")
        await cp.disconnect()
        #expect(await !cp.isLinkUp)
    }

    @Test func setIsConfirmedAndReadBack() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port)
        #expect(await cp.connect())
        #expect(try await cp.set("fader_level", 50))
        #expect(await eventually { await known(cp, "fader_level") == "50" })
        #expect(try await cp.get("fader_level", timeout: 0.5) == "50")
        #expect(try await cp.set("mute", "1"))
        #expect(await eventually { await known(cp, "mute") == "1" })
        #expect(try await cp.get("mute", timeout: 0.5) == "1")
        await cp.disconnect()
    }

    @Test func unknownParamTimesOutAndTheLinkStillWorks() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port, getRetries: 0)
        #expect(await cp.connect())
        #expect(try await cp.get("no_such_param", timeout: 0.5) == nil)
        #expect(try await cp.get("mute", timeout: 0.5) == "0")
        await cp.disconnect()
    }

    @Test func concurrentCallsAreSerialized() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port)
        #expect(await cp.connect())
        async let fader = cp.get("fader_level", timeout: 0.5)
        async let mute = cp.get("mute", timeout: 0.5)
        async let format = cp.get("format_button", timeout: 0.5)
        let values = try await [fader, mute, format]
        #expect(values == ["70", "0", "1"])
        await cp.disconnect()
    }

    @Test func peerCloseDropsTheLinkAndGetReturnsNil() async throws {
        let sim = try await Simulator()
        let cp = fastClient(sim.port)
        #expect(await cp.connect())
        sim.stop()
        #expect(await eventually { await !cp.isLinkUp })
        #expect(try await cp.get("mute", timeout: 0.5) == nil)
        #expect(await cp.status == .missing)
    }

    @Test func invalidCommandIsRejectedBeforeSending() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port)
        #expect(await cp.connect())
        await #expect(throws: ProtocolError.self) { try await cp.set("mute", "1\nfader_level=0") }
        #expect(try await cp.get("fader_level", timeout: 0.5) == "70")
        await cp.disconnect()
    }
}

@Suite(.serialized, .enabled(if: simulatorPath != nil, "needs CPSIM_BIN (the simulator)"))
struct DolbyCPSupervisionTests {
    @Test func statusFollowsTheLink() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port)
        #expect(await cp.status == .initializing)
        #expect(await cp.connect())
        #expect(await cp.status == .ok)
        await cp.disconnect()
        #expect(await cp.status == .missing)
    }

    @Test func statusUpdatesStreamReportsChanges() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port)
        #expect(await cp.connect())
        await cp.disconnect()
        var seen: [ProcessorStatus] = []
        for await status in cp.statusUpdates {
            seen.append(status)
            if seen.count == 2 { break }
        }
        #expect(seen == [.ok, .missing])
    }

    @Test func withoutAutoReconnectADroppedLinkStaysDown() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port)
        #expect(await cp.connect())
        sim.dropConnections()
        #expect(await eventually { await cp.status == .missing })
        try await Task.sleep(for: .milliseconds(500))
        #expect(await !cp.isLinkUp)
        #expect(try await cp.get("mute", timeout: 0.5) == nil)
    }

    @Test func watchdogReconnectsADroppedLink() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port, autoReconnect: true)
        #expect(await cp.connect())
        sim.dropConnections()
        #expect(await eventually { await !cp.isLinkUp })
        #expect(await eventually { await isUpAndOk(cp) })
        #expect(try await cp.get("fader_level", timeout: 0.5) == "70")
        await cp.disconnect()
    }

    @Test func getReconnectsBeforeSending() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port, autoReconnect: true, pollInterval: 60)   // watchdog out of the way
        #expect(await cp.connect())
        sim.dropConnections()
        #expect(await eventually { await !cp.isLinkUp })
        #expect(try await cp.get("fader_level", timeout: 0.5) == "70")
        #expect(await cp.isLinkUp)
        await cp.disconnect()
    }

    @Test func setWhileDownIsDeliveredAfterReconnect() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port, autoReconnect: true)
        #expect(await cp.connect())
        sim.dropConnections()
        #expect(await eventually { await !cp.isLinkUp })
        #expect(try await cp.set("fader_level", 40))
        #expect(await eventually { await known(cp, "fader_level") == "40" })
        #expect(await cp.pendingSets.isEmpty)
        #expect(try await cp.get("fader_level", timeout: 0.5) == "40")
        await cp.disconnect()
    }

    @Test func setWhileDownWithoutAutoReconnectIsRefused() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port)
        #expect(await cp.connect())
        sim.dropConnections()
        #expect(await eventually { await !cp.isLinkUp })
        #expect(try await cp.set("fader_level", 40) == false)
        #expect(await cp.pendingSets.isEmpty)
    }

    @Test func reconnectsOnceTheProcessorComesBack() async throws {
        let first = try await Simulator()
        let port = first.port
        let cp = fastClient(port, autoReconnect: true)
        #expect(await cp.connect())
        first.stop()
        #expect(await eventually { await cp.status == .missing })
        try await Task.sleep(for: .milliseconds(600))   // several failed attempts
        #expect(await !cp.isLinkUp)
        let second = try await Simulator(port: port)
        defer { second.stop() }
        #expect(await eventually(5) { await isUpAndOk(cp) })
        #expect(try await cp.get("mute", timeout: 0.5) == "0")
        await cp.disconnect()
    }

    @Test func activePollTripsOnASilentProcessor() async throws {
        let sim = try await Simulator(extraArguments: ["--silent"])
        defer { sim.stop() }
        let cp = fastClient(sim.port, pollParam: "mute")
        #expect(await cp.connect())
        #expect(await cp.status == .ok)
        #expect(await eventually(6) { await cp.status == .missing })
        await cp.disconnect()
    }

    @Test func activePollKeepsAnAliveLinkOk() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port, pollParam: "mute")
        #expect(await cp.connect())
        try await Task.sleep(for: .seconds(1.2))   // twice the watchdog limit
        #expect(await cp.status == .ok)
        #expect(await cp.isLinkUp)
        await cp.disconnect()
    }

    @Test func passiveWatchdogNeverTripsAnIdleLink() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port)
        #expect(await cp.connect())
        try await Task.sleep(for: .seconds(1.2))
        #expect(await cp.status == .ok)
        await cp.disconnect()
    }

    @Test func disconnectStopsAutoReconnect() async throws {
        let sim = try await Simulator()
        defer { sim.stop() }
        let cp = fastClient(sim.port, autoReconnect: true)
        #expect(await cp.connect())
        await cp.disconnect()
        try await Task.sleep(for: .milliseconds(500))
        #expect(await !cp.isLinkUp)
        #expect(try await cp.set("mute", "1"))           // queued: auto-reconnect is on
        try await Task.sleep(for: .milliseconds(300))
        #expect(await !cp.isLinkUp)                      // but nothing reopens the link
    }
}

@Suite(.serialized, .enabled(if: simulatorPath != nil, "needs CPSIM_BIN (the simulator)"))
struct DolbyCPSetQueueTests {
    /// A client whose link is held by a `get` of an unknown param (one 0.5 s
    /// attempt), so SETs made meanwhile wait in the queue.
    func busyClient(_ sim: Simulator) async -> DolbyCP {
        let cp = fastClient(sim.port, getRetries: 0)
        _ = await cp.connect()
        return cp
    }

    @Test func repeatedSetsCoalesceOnTheWire() async throws {
        let sim = try await Simulator(extraArguments: ["--log"])
        defer { sim.stop() }
        let cp = await busyClient(sim)
        async let slow = cp.get("no_such_param", timeout: 0.5)
        try await Task.sleep(for: .milliseconds(150))   // the get holds the link
        for level in 1...5 { try await cp.set("fader_level", .int(level)) }
        #expect(await cp.pendingSets == [PendingSet(param: "fader_level", value: 5)])
        _ = try await slow
        #expect(await eventually { await known(cp, "fader_level") == "5" })
        #expect(await eventually { sim.received().filter { $0.hasPrefix("fader_level=") } == ["fader_level=5"] })
        await cp.disconnect()
    }

    @Test func overflowDropsTheOldestSets() async throws {
        let sim = try await Simulator(extraArguments: ["--log"])
        defer { sim.stop() }
        let cp = await busyClient(sim)
        async let slow = cp.get("no_such_param", timeout: 0.5)
        try await Task.sleep(for: .milliseconds(150))
        for index in 0..<12 { try await cp.set("p\(index)", .int(index)) }
        let pending = await cp.pendingSets.map(\.param)
        #expect(pending == (2..<12).map { "p\($0)" })
        _ = try await slow
        #expect(await eventually {
            let pending = await cp.pendingSets
            let known = await cp.stateDict
            return pending.isEmpty && known.count == 10
        })
        let sent = sim.received().filter { $0.hasPrefix("p") }
        #expect(sent == (2..<12).map { "p\($0)=\($0)" })
        await cp.disconnect()
    }
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

/// The control client for one Dolby CP650–CP950A processor (the Swift port
///
///    a background task sends the queue one command at a time, dequeuing only
///    once it holds the link, requeueing a SET whose send never reached the
/// 2. `get` is the one blocking call: it waits its turn, retries a lost
///    the status: a parsed reply or `ACK` → ok, no line at all → missing, a
/// 4. A SET counts as applied when its reply does not parse at all, or names
///
/// returns false, `get` returns nil and the status says why. Only a command
/// that cannot be framed throws (`ProtocolError`).
public actor DolbyCP {
    static let resyncMax = 32

    public nonisolated let model: ProcessorModel
    /// The TCP port; nil for a client built on a custom transport.
    public nonisolated let port: UInt16?
    public nonisolated let pollInterval: Double
    public nonisolated let pollParam: String?
    public nonisolated let watchdog: Double
    public nonisolated let autoReconnect: Bool
    public nonisolated let reconnectBackoff: (initial: Double, max: Double)
    public nonisolated let getRetries: Int
    /// Seconds waited after each send before the reply is read.
    public nonisolated let gap: Double
    /// Every status change, for one consumer (a UI).
    public nonisolated let statusUpdates: AsyncStream<ProcessorStatus>

    private let transport: any LineTransport
    private var state = ProcessorState()
    private var queue = CommandQueue()
    public private(set) var droppedCommands = 0
    public private(set) var lastDropError: String?

    private let statusContinuation: AsyncStream<ProcessorStatus>.Continuation
    private var drainTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private var backoff: Double
    private var busy = false
    private var turnQueue: [CheckedContinuation<Void, Never>] = []

    /// A client over TCP to `host`, on `port` or the model's default port.
    public init(host: String, port: UInt16? = nil, model: ProcessorModel = .cp750,
                pollInterval: Double = ProtocolTiming.defaultPollInterval, pollParam: String? = nil,
                watchdog: Double = ProtocolTiming.watchdog, autoReconnect: Bool = false,
                reconnectBackoff: (initial: Double, max: Double) = (0.1, 2.0), getRetries: Int = 2,
                gap: Double? = nil) {
        let resolved = port ?? model.defaultPort
        self.init(transport: TCPTransport(host: host, port: resolved), port: resolved, model: model,
                  pollInterval: pollInterval, pollParam: pollParam, watchdog: watchdog,
                  autoReconnect: autoReconnect, reconnectBackoff: reconnectBackoff,
                  getRetries: getRetries, gap: gap)
    }

    public static func overSerial(device: String, model: ProcessorModel = .cp750, baudrate: Int = 115200,
                                  pollInterval: Double = ProtocolTiming.defaultPollInterval,
                                  pollParam: String? = nil, watchdog: Double = ProtocolTiming.watchdog,
                                  autoReconnect: Bool = false,
                                  reconnectBackoff: (initial: Double, max: Double) = (0.1, 2.0),
                                  getRetries: Int = 2, gap: Double? = nil) -> DolbyCP {
        DolbyCP(transport: SerialTransport(device: device, baudrate: baudrate), model: model,
                pollInterval: pollInterval, pollParam: pollParam, watchdog: watchdog,
                autoReconnect: autoReconnect, reconnectBackoff: reconnectBackoff,
                getRetries: getRetries, gap: gap)
    }

    /// A client over an explicit transport (a serial link, a test double).
    public init(transport: any LineTransport, model: ProcessorModel = .cp750,
                pollInterval: Double = ProtocolTiming.defaultPollInterval, pollParam: String? = nil,
                watchdog: Double = ProtocolTiming.watchdog, autoReconnect: Bool = false,
                reconnectBackoff: (initial: Double, max: Double) = (0.1, 2.0), getRetries: Int = 2,
                gap: Double? = nil) {
        self.init(transport: transport, port: nil, model: model, pollInterval: pollInterval,
                  pollParam: pollParam, watchdog: watchdog, autoReconnect: autoReconnect,
                  reconnectBackoff: reconnectBackoff, getRetries: getRetries, gap: gap)
    }

    private init(transport: any LineTransport, port: UInt16?, model: ProcessorModel,
                 pollInterval: Double, pollParam: String?, watchdog: Double, autoReconnect: Bool,
                 reconnectBackoff: (initial: Double, max: Double), getRetries: Int, gap: Double?) {
        self.transport = transport
        self.port = port
        self.model = model
        self.pollInterval = pollInterval
        self.pollParam = pollParam
        self.watchdog = watchdog
        self.autoReconnect = autoReconnect
        self.reconnectBackoff = reconnectBackoff
        self.getRetries = getRetries
        self.gap = gap ?? model.commandGap
        self.backoff = reconnectBackoff.initial
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(of: ProcessorStatus.self)
    }

    deinit {
        drainTask?.cancel()
        watchdogTask?.cancel()
        statusContinuation.finish()
    }

    // MARK: - State

    public var status: ProcessorStatus { state.status }

    /// insertion order; a SET records the value it sent, a query the text it got.
    public var stateDict: [(param: String, value: WireValue)] { state.values }

    /// SETs queued and not yet sent.
    public var pendingSets: [PendingSet] { queue.items }

    /// The SET being sent right now, out of the queue and not yet answered.
    public var inflightSet: PendingSet? { queue.inflight }

    /// The link is usable: open, and not closed by the peer.
    public var isLinkUp: Bool {
        get async { await linkUp() }
    }

    // MARK: - Lifecycle

    /// Open the transport and start the drain and watchdog tasks. True on
    /// success; the status is ok or missing.
    public func connect() async -> Bool {
        await enterLifecycle()
        defer { leaveLifecycle() }
        return await connectUnlocked()
    }

    /// Close the current link and open a fresh one. Queued commands survive.
    public func reconnect() async -> Bool {
        await enterLifecycle()
        defer { leaveLifecycle() }
        await stopBackground()
        await transport.close()
        return await connectUnlocked()
    }

    /// Stop the background tasks, close the link, status missing.
    public func disconnect() async {
        await enterLifecycle()
        defer { leaveLifecycle() }
        await stopBackground()
        await transport.close()
        mark(.missing)
    }

    private func connectUnlocked() async -> Bool {
        await stopBackground()
        let ok = await transport.connect()
        mark(ok ? .ok : .missing)
        if ok {
            lastActivity = .now
            startBackground()
        }
        return ok
    }

    // MARK: - Lifecycle gate

    /// `connect`, `reconnect` and `disconnect` run one at a time, in call
    /// order: two overlapping calls could otherwise both start background
    /// tasks, and the orphaned pair would outlive `disconnect()`.
    private var lifecycleBusy = false
    private var lifecycleQueue: [CheckedContinuation<Void, Never>] = []

    private func enterLifecycle() async {
        if !lifecycleBusy {
            lifecycleBusy = true
            return
        }
        await withCheckedContinuation { lifecycleQueue.append($0) }
    }

    private func leaveLifecycle() {
        if lifecycleQueue.isEmpty {
            lifecycleBusy = false
        } else {
            lifecycleQueue.removeFirst().resume()
        }
    }

    // MARK: - Commands

    /// Queue a SET and return at once. Throws, queueing nothing, when the
    /// param or value cannot be framed; false, queueing nothing, when the link
    /// is down and `autoReconnect` is off.
    @discardableResult
    public func set(_ param: String, _ value: WireValue, timeout: Double = 0.5) async throws(ProtocolError) -> Bool {
        _ = try WireProtocol.formatSet(model: model, param: param, value: value)
        if !(await linkUp()), !autoReconnect { return false }
        queue.enqueue(PendingSet(param: param, value: value, timeout: timeout))
        return true
    }

    /// Query `param`: its value, or nil on timeout, a dead link, or a reply
    /// that does not name it. The link is checked before the param is framed.
    public func get(_ param: String, timeout: Double = ProtocolTiming.queryTimeout) async throws(ProtocolError) -> String? {
        if !(await linkUp()), autoReconnect { _ = await reconnectTransport() }
        if !(await linkUp()) {
            mark(.missing)
            return nil
        }
        let line = try WireProtocol.formatQuery(model: model, param: param)
        let attempts = getRetries + 1
        for attempt in 0..<attempts {
            await acquire()
            let response = await transact(line, timeout: timeout, expect: param).response
            release()
            if let response,
               let pair = WireProtocol.parseResponse(model: model, text: response)
                .first(where: { sameScalars($0.param, param) }) {
                state.set(param, .string(pair.value))
                return pair.value
            }
            if attempt < attempts - 1, !(await linkUp()), autoReconnect {
                _ = await reconnectTransport()
            }
        }
        return nil
    }

    /// Wait until the queue is empty and nothing is in flight; true if that
    /// happened within `timeout`.
    public func settle(timeout: Double = 5) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if queue.isEmpty, !queue.hasInflight, !busy { return true }
            do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }   // cancelled
        }
        return queue.isEmpty && !queue.hasInflight && !busy
    }

    /// `cp._queue.enqueue(...)`), for tests of the drop path.
    func enqueueUnchecked(_ command: PendingSet) {
        queue.enqueue(command)
    }

    // MARK: - Background tasks

    private func startBackground() {
        drainTask?.cancel()      // never leave an earlier pair running
        watchdogTask?.cancel()
        let interval = pollInterval
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.drainStep()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                await self.watchdogTick()
            }
        }
    }

    /// `_stop_background` gathers them). Swift cancellation is cooperative,
    /// so each task checks it after every wait.
    private func stopBackground() async {
        let tasks = [drainTask, watchdogTask].compactMap { $0 }
        drainTask = nil
        watchdogTask = nil
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    /// One drain pass: send the head of the queue if the link is up. The
    /// command leaves the queue only once the lock is held.
    private func drainStep() async {
        guard !queue.isEmpty, await linkUp() else { return }
        await acquire()
        defer { release() }
        guard !Task.isCancelled, await linkUp(), let command = queue.dequeue() else { return }
        let line: String
        do {
            line = try WireProtocol.formatSet(model: model, param: command.param, value: command.value)
        } catch {
            drop(command, error)
            return
        }
        queue.setInflight(command)
        let outcome = await transact(line, timeout: command.timeout, expect: nil)
        if confirmsSet(outcome.response, command.param) {
            state.set(command.param, command.value)
        }
        queue.clearInflight()
        if !outcome.reachedWire { queue.requeueFront(command) }
    }

    private func drop(_ command: PendingSet, _ error: ProtocolError) {
        droppedCommands += 1
        lastDropError = "\(command.param.debugDescription): \(error)"
    }

    private func watchdogTick() async {
        guard !Task.isCancelled else { return }
        if !(await linkUp()) {
            mark(.missing)
            if autoReconnect { await autoReconnectStep() }
            return
        }
        guard let pollParam, !pollParam.isEmpty else { return }
        if queue.isEmpty { await pollOnce(pollParam) }
        if ContinuousClock.now - lastActivity > .seconds(watchdog) {
            mark(.missing)
            if autoReconnect { await autoReconnectStep() }
        }
    }

    private func pollOnce(_ param: String) async {
        guard let line = try? WireProtocol.formatQuery(model: model, param: param) else { return }
        await acquire()
        guard !Task.isCancelled else {
            release()
            return
        }
        let response = await transact(line, timeout: ProtocolTiming.queryTimeout, expect: param).response
        release()
        if let response {
            for pair in WireProtocol.parseResponse(model: model, text: response)
            where sameScalars(pair.param, param) {
                state.set(param, .string(pair.value))
            }
        }
    }

    /// Swap in a fresh link without stopping the background tasks.
    private func reconnectTransport() async -> Bool {
        await acquire()
        defer { release() }
        // A watchdog cancelled while it waited for the lock (disconnect)
        // must not reopen the link.
        guard !Task.isCancelled else { return false }
        await transport.close()
        let ok = await transport.connect()
        mark(ok ? .ok : .missing)
        if ok { lastActivity = .now }
        return ok
    }

    private func autoReconnectStep() async {
        try? await Task.sleep(for: .seconds(backoff))
        guard !Task.isCancelled else { return }
        let ok = await reconnectTransport()
        backoff = ok ? reconnectBackoff.initial : min(backoff * 2, reconnectBackoff.max)
    }

    // MARK: - Round trip

    private func linkUp() async -> Bool {
        let connected = await transport.isConnected()
        guard connected else { return false }
        return !(await transport.peerClosed())
    }

    /// Send one line and read its reply. Must hold the lock. `reachedWire`
    /// is true once the send succeeded, so the drain loop can tell a lost
    /// link (requeue) from a send that drew no or a bad reply (delivered).
    private func transact(_ line: String, timeout: Double, expect: String?) async
        -> (response: String?, reachedWire: Bool)
    {
        guard await transport.isConnected() else {
            mark(.missing)
            return (nil, false)
        }
        var response: String?
        var gotLine = false
        var parsedOk = false
        do {
            try await transport.sendLine(line)
        } catch {
            mark(.missing)
            return (nil, false)
        }
        try? await Task.sleep(for: .seconds(gap))
        response = await transport.readLine(timeout: timeout)
        if model == .cp650, let echo = response, sameScalars(echo, line) {
            response = await transport.readLine(timeout: timeout)   // the CP650 echo
        }
        var pairs: [ResponsePair] = []
        if let reply = response {
            gotLine = true
            pairs = WireProtocol.parseResponse(model: model, text: reply)
            parsedOk = !pairs.isEmpty || CP650Ack.isAck(reply)
        }
        if let expect, response != nil {
            var skipped = 0
            while !pairs.contains(where: { sameScalars($0.param, expect) }) {
                if skipped >= Self.resyncMax {
                    response = nil
                    break
                }
                response = await transport.readLine(timeout: timeout)
                guard let reply = response else { break }
                gotLine = true
                skipped += 1
                pairs = WireProtocol.parseResponse(model: model, text: reply)
                if !pairs.isEmpty || CP650Ack.isAck(reply) { parsedOk = true }
            }
        }
        if parsedOk {
            mark(.ok)
            lastActivity = .now
        } else if !gotLine {
            mark(.missing)
        }
        return (response, true)
    }

    /// anything else that does not parse) → applied; else it must name the param.
    private func confirmsSet(_ response: String?, _ param: String) -> Bool {
        guard let response else { return false }
        let pairs = WireProtocol.parseResponse(model: model, text: response)
        return pairs.isEmpty || pairs.contains { sameScalars($0.param, param) }
    }

    private func mark(_ newStatus: ProcessorStatus) {
        let changed = newStatus != state.status
        state.mark(newStatus)
        if changed { statusContinuation.yield(newStatus) }
    }

    // MARK: - One command in flight (FIFO, as asyncio.Lock)

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { turnQueue.append($0) }
    }

    private func release() {
        if turnQueue.isEmpty {
            busy = false
        } else {
            turnQueue.removeFirst().resume()
        }
    }
}

enum CP650Ack {
    static func isAck(_ line: String) -> Bool {
        WireProtocol.pythonStripped(line).uppercased().unicodeScalars.elementsEqual("ACK".unicodeScalars)
    }
}

/// The control client for one Dolby CP650–CP950A processor, over any
/// `LineTransport`.
///
/// 1. `set` queues the SET and returns at once; a background task sends the
///    queue one command at a time, dequeuing only once it holds the link, and
///    requeues a SET whose send never reached the wire.
/// 2. `get` is the one blocking call: it waits its turn, retries a lost or
///    timed-out query, and skips stale lines that do not name the param.
///    On a model with two query forms (the CP650), each retry uses the next
///    form; once the preferred form has gone unanswered twice in a row and
///    the other is answered, the other is used from then on.
/// 3. Every exchange updates the status: a parsed reply or `ACK` → ok, no
///    line at all → missing; a line that does not parse leaves it as it is.
/// 4. A SET counts as applied when its reply does not parse at all, or names
///    the param.
///
/// Connection problems are never thrown: `connect` returns false, `get`
/// returns nil, and the status says why. Only a command that cannot be
/// framed throws (`ProtocolError`).
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

    private let statusContinuation: AsyncStream<ProcessorStatus>.Continuation
    private var drainTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private var backoff: Double
    private var busy = false
    /// Receives one line per event of the link; nil by default.
    private var eventLog: (@Sendable (String) -> Void)?
    private var turnQueue: [CheckedContinuation<Void, Never>] = []
    /// The index, in `WireProtocol.queryForms`, of the query form to send:
    /// the one the processor answers.
    private var queryForm = 0
    /// Queries in the preferred form left unanswered in a row. The form is
    /// switched only once it reaches `formMissLimit` and the other form is
    /// answered: one late reply to the preferred form, read as the answer to
    /// the other, must not switch it.
    private var formMisses = 0
    private static let formMissLimit = 2

    /// A query in `form` was answered (`answered`) or not: keep or switch
    /// the preferred form.
    private func noteQuery(form: Int, answered: Bool, line: String) {
        if form == queryForm {
            formMisses = answered ? 0 : formMisses + 1
        } else if answered, formMisses >= Self.formMissLimit {
            queryForm = form
            formMisses = 0
            record("queries are sent as \(line) from now on")
        }
    }

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

    /// A client over a serial device, at the processors' 9600 baud by default.
    public static func overSerial(device: String, model: ProcessorModel = .cp750, baudrate: Int = 9600,
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
        // Every time and count is made safe here: an infinite, negative or
        // NaN value used to trap in Duration.seconds or a Range.
        self.pollInterval = ProtocolTiming.clamped(pollInterval, floor: 0.01)
        self.pollParam = pollParam
        self.watchdog = ProtocolTiming.clamped(watchdog)
        self.autoReconnect = autoReconnect
        let initial = ProtocolTiming.clamped(reconnectBackoff.initial, floor: 0.01)
        self.reconnectBackoff = (initial, max(initial, ProtocolTiming.clamped(reconnectBackoff.max)))
        self.getRetries = ProtocolTiming.clampedRetries(getRetries)
        self.gap = ProtocolTiming.clamped(gap ?? model.commandGap)
        self.backoff = initial
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(of: ProcessorStatus.self)
    }

    deinit {
        drainTask?.cancel()
        watchdogTask?.cancel()
        statusContinuation.finish()
    }

    // MARK: - State

    public var status: ProcessorStatus { state.status }

    /// Every last-known `(param, value)`, in first insertion order; a SET
    /// records the value it sent, a query the text it got.
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

    /// Open the transport (keeping a link that is already up) and start the
    /// drain and watchdog tasks. True on success; the status is ok or missing.
    public func connect() async -> Bool {
        await enterLifecycle()
        defer { leaveLifecycle() }
        return await openAndStart(fresh: false, event: "connect")
    }

    /// Close the current link and open a fresh one. Queued commands survive.
    public func reconnect() async -> Bool {
        await enterLifecycle()
        defer { leaveLifecycle() }
        return await openAndStart(fresh: true, event: "connect")
    }

    /// Seconds to wait between closing a link that was up and opening the
    /// next one, so a processor that takes a single connection has dropped
    /// the old session first (the Q-SYS plugin waits two seconds). Zero by
    /// default.
    public func setReopenPause(_ seconds: Double) { reopenPause = ProtocolTiming.clamped(seconds) }
    private var reopenPause: Double = 0
    /// When this client last closed a link that was up.
    private var lastClose: ContinuousClock.Instant?

    /// Wait out what is left of the reopen pause since the last close.
    private func pauseBeforeReopen() async {
        guard reopenPause > 0, let lastClose else { return }
        let left = lastClose + .seconds(reopenPause) - .now
        if left > .zero { try? await Task.sleep(for: left) }
    }

    /// Seconds to listen on a freshly opened link before the first command.
    /// The CP650 sends a line of its own when a front-panel key is pressed,
    /// and a unit that another controller polls can be busy: listening first
    /// reads what it pushes, and sends nothing. Zero, the default, sends at once.
    public func setListenWindow(_ seconds: Double) { listenWindow = ProtocolTiming.clamped(seconds) }
    private var listenWindow: Double = 0
    /// Most lines read in one listen window, so a line that never stops cannot
    /// hold the link open.
    static let listenMaxLines = 64

    /// Read the lines the unit pushes until one window passes in silence, and
    /// apply the ones that parse. Nothing is sent. A line that does not parse
    /// is noted and skipped.
    private func listenBeforeFirstCommand() async {
        guard listenWindow > 0 else { return }
        var lines = 0
        while lines < Self.listenMaxLines, let line = await transport.readLine(timeout: listenWindow) {
            lines += 1
            record("listen recv \(line)")
            for pair in WireProtocol.parseResponse(model: model, text: line) where !sameScalars(pair.value, "?") {
                state.set(pair.param, .string(pair.value))
            }
        }
        record("listen: \(lines) line(s) before the first command")
    }

    /// Close the transport; a link that was up starts the reopen pause.
    private func closeTransport() async {
        let wasUp = await linkUp()
        await transport.close()
        if wasUp { lastClose = .now }
    }

    /// The lifecycle body of `connect` and `reconnect`: stop the background
    /// tasks, open under the command lock, then start them again.
    private func openAndStart(fresh: Bool, event: String) async -> Bool {
        disconnected = false
        await stopBackground()
        let ok = await openLocked(fresh: fresh)
        record("\(event) \(ok ? "succeeded" : "failed")")
        mark(ok ? .ok : .missing, event)
        if ok {
            lastActivity = .now
            startBackground()
        }
        return ok
    }

    /// Hold the command lock from the close, through the reopen pause, to the
    /// open, so no other path can open a session in between (a processor that
    /// takes one connection ignores a second). Without `fresh`, a link that
    /// is up is kept.
    private func openLocked(fresh: Bool) async -> Bool {
        await acquire()
        defer { release() }
        if !fresh, await linkUp() { return true }
        await closeTransport()
        await pauseBeforeReopen()
        guard await transport.connect() else { return false }
        await listenBeforeFirstCommand()
        return true
    }

    /// Stop the background tasks, close the link, status missing.
    public func disconnect() async {
        await enterLifecycle()
        defer { leaveLifecycle() }
        record("disconnect")
        disconnected = true
        await stopBackground()
        await closeLocked()
        mark(.missing, "disconnect")
    }

    /// Set by `disconnect()`, cleared by `connect()` and `reconnect()`: a
    /// `get` still running must not reopen a link the caller closed.
    private var disconnected = false

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
        queue.enqueue(PendingSet(param: param, value: value, timeout: ProtocolTiming.clamped(timeout)))
        signalWork()
        return true
    }

    /// Query `param`: its value, or nil on timeout, a dead link, or a reply
    /// that does not name it. The link is checked before the param is framed.
    public func get(_ param: String, timeout: Double = ProtocolTiming.queryTimeout) async throws(ProtocolError) -> String? {
        let timeout = ProtocolTiming.clamped(timeout)
        if !(await linkUp()), autoReconnect { _ = await reopenForCommand() }
        if !(await linkUp()) {
            mark(.missing, "get: link is down")
            return nil
        }
        let forms = try WireProtocol.queryForms(model: model, param: param)
        let attempts = getRetries + 1
        for attempt in 0..<attempts {
            let form = (queryForm + attempt) % forms.count
            let line = forms[form]
            await acquire()
            let response = await transact(line, timeout: timeout, expect: param).response
            release()
            let pair = response.flatMap { reply in
                WireProtocol.parseResponse(model: model, text: reply)
                    .first(where: { sameScalars($0.param, param) && !sameScalars($0.value, "?") })
            }
            if forms.count > 1 { noteQuery(form: form, answered: pair != nil, line: line) }
            if let pair {
                state.set(param, .string(pair.value))
                return pair.value
            }
            if attempt < attempts - 1, !(await linkUp()), autoReconnect {
                _ = await reopenForCommand()
            }
        }
        return nil
    }

    /// Query a parameter whose reply is several lines: the header line that
    /// names it, then one line per item (the CP850 / CP950 `sys.macros`).
    /// The items are the lines that follow the header, each waited for up to
    /// `itemTimeout`, at most `limit` of them. Stale or unsolicited lines
    /// before the header are skipped (at most `resyncMax`), as `get` does.
    /// Nil when the header does not come.
    public func getList(_ param: String, timeout: Double = ProtocolTiming.queryTimeout,
                        itemTimeout: Double = 0.3, limit: Int = 64) async throws(ProtocolError) -> [String]? {
        let timeout = ProtocolTiming.clamped(timeout)
        let itemTimeout = ProtocolTiming.clamped(itemTimeout)
        if !(await linkUp()), autoReconnect { _ = await reopenForCommand() }
        if !(await linkUp()) {
            mark(.missing, "get: link is down")
            return nil
        }
        let line = try preferredQuery(param)
        await acquire()
        defer { release() }
        do {
            try await transport.sendLine(line)
            record("send \(line)")
        } catch {
            record("send failed: \(line) (\(error))")
            mark(.missing, "send failed")
            return nil
        }
        try? await Task.sleep(for: .seconds(gap))
        var skipped = 0
        while true {
            guard let header = await readLogged(timeout: timeout) else {
                if skipped == 0 { mark(.missing, "no reply to \(line) within \(timeout) s") }
                return nil
            }
            let name = header.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? header
            if sameScalars(name, param) { break }
            skipped += 1
            if skipped > Self.resyncMax {
                record("gave up looking for \(param) after \(skipped) other lines")
                return nil
            }
        }
        mark(.ok)
        lastActivity = .now
        var items: [String] = []
        while items.count < limit, let item = await readLogged(timeout: itemTimeout) {
            let text = item.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { items.append(text) }
        }
        return items
    }

    /// Wait until the queue is empty and nothing is in flight; true if that
    /// happened within `timeout`.
    public func settle(timeout: Double = 5) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(ProtocolTiming.clamped(timeout))
        while ContinuousClock.now < deadline {
            if queue.isEmpty, !queue.hasInflight, !busy { return true }
            do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }   // cancelled
        }
        return queue.isEmpty && !queue.hasInflight && !busy
    }

    // MARK: - Background tasks

    /// Drain and watchdog tasks running now (for tests: one pair at most).
    private(set) var backgroundTasks = 0
    /// Drain passes made so far (for tests: an idle link makes none).
    private(set) var drainPasses = 0
    /// The drain task waiting for work, resumed by `set` or a reopen.
    private var workWaiter: CheckedContinuation<Void, Never>?

    private func startBackground() {
        drainTask?.cancel()      // never leave an earlier pair running
        watchdogTask?.cancel()
        let interval = pollInterval
        drainTask = Task { [weak self] in
            await self?.taskStarted()
            while !Task.isCancelled {
                guard let self else { return }
                await self.drainStep()
                // Idle (nothing queued) it waits for `set` to wake it; with
                // SETs queued (the link down, say) it looks again in 10 ms.
                if await self.hasNoWork() {
                    await self.waitForWork()
                } else {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            await self?.taskEnded()
        }
        watchdogTask = Task { [weak self] in
            await self?.taskStarted()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { break }
                await self.watchdogTick()
            }
            await self?.taskEnded()
        }
    }

    private func taskStarted() { backgroundTasks += 1 }
    private func taskEnded() { backgroundTasks -= 1 }

    private func hasNoWork() -> Bool { queue.isEmpty }

    /// Suspend the drain task until `signalWork` (a SET queued, a link
    /// reopened, the task cancelled).
    private func waitForWork() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || !queue.isEmpty {
                    continuation.resume()
                } else {
                    workWaiter = continuation
                }
            }
        } onCancel: {
            Task { await self.signalWork() }
        }
    }

    private func signalWork() {
        workWaiter?.resume()
        workWaiter = nil
    }

    /// Cancel the drain and watchdog tasks and wait for both to end. Swift
    /// cancellation is cooperative, so each task checks it after every wait.
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
        drainPasses += 1
        guard !queue.isEmpty, await linkUp() else { return }
        await acquire()
        defer { release() }
        guard !Task.isCancelled, await linkUp(), let command = queue.dequeue() else { return }
        // `set` framed it before queueing it, so this cannot fail.
        guard let line = try? WireProtocol.formatSet(model: model, param: command.param, value: command.value)
        else { return }
        queue.setInflight(command)
        let outcome = await transact(line, timeout: command.timeout, expect: nil, setParam: command.param)
        if confirmsSet(outcome.response, command.param) {
            state.set(command.param, command.value)
        }
        queue.clearInflight()
        if !outcome.reachedWire { queue.requeueFront(command) }
    }

    private func watchdogTick() async {
        guard !Task.isCancelled else { return }
        if !(await linkUp()) {
            mark(.missing, "watchdog: link is down")
            if autoReconnect { await autoReconnectStep() }
            return
        }
        guard let pollParam, !pollParam.isEmpty else { return }
        if queue.isEmpty { await pollOnce(pollParam) }
        if ContinuousClock.now - lastActivity > .seconds(watchdog) {
            mark(.missing, "watchdog: no reply for \(watchdog) s")
            if autoReconnect { await autoReconnectStep() }
        }
    }

    /// The watchdog's poll: the preferred query form, then (on a model with
    /// two, the CP650) the other one, as `get` retries do; the form answered
    /// is kept.
    private func pollOnce(_ param: String) async {
        guard let forms = try? WireProtocol.queryForms(model: model, param: param) else { return }
        for attempt in 0..<forms.count {
            let form = (queryForm + attempt) % forms.count
            await acquire()
            guard !Task.isCancelled else {
                release()
                return
            }
            let response = await transact(forms[form], timeout: ProtocolTiming.queryTimeout, expect: param).response
            release()
            let pair = response.flatMap { reply in
                WireProtocol.parseResponse(model: model, text: reply)
                    .first(where: { sameScalars($0.param, param) && !sameScalars($0.value, "?") })
            }
            if forms.count > 1 { noteQuery(form: form, answered: pair != nil, line: forms[form]) }
            guard let pair else { continue }
            state.set(param, .string(pair.value))
            return
        }
    }

    /// Reopen a link that is down, holding the command lock from the close to
    /// the open. A link another path reopened while this one waited for the
    /// lock is kept as it is (queued reopens coalesce).
    private func reopenLink() async -> Bool {
        await acquire()
        defer { release() }
        // A watchdog cancelled while it waited for the lock (disconnect), or
        // a `get` from any task after `disconnect()`, must not reopen the link.
        guard !Task.isCancelled, !disconnected else { return false }
        if await linkUp() { return true }
        await closeTransport()
        await pauseBeforeReopen()
        guard !Task.isCancelled, !disconnected else { return false }
        let ok = await transport.connect()
        record("reconnect \(ok ? "succeeded" : "failed")")
        mark(ok ? .ok : .missing, "reconnect")
        if ok { lastActivity = .now }
        return ok
    }

    /// The reopen of `get` and `getList`: inside the lifecycle gate, so it
    /// never overlaps `connect`, `reconnect` or `disconnect`, and it starts
    /// the drain and watchdog tasks when they are not running (after a
    /// failed connect, nothing else would send the queued SETs).
    private func reopenForCommand() async -> Bool {
        await enterLifecycle()
        defer { leaveLifecycle() }
        let ok = await reopenLink()
        if ok, drainTask == nil, !disconnected { startBackground() }
        return ok
    }

    /// The watchdog's reopen. It cannot wait for the lifecycle gate (a
    /// lifecycle call stops the watchdog and waits for it to end), so it
    /// leaves the link to a lifecycle call in progress.
    private func autoReconnectStep() async {
        try? await Task.sleep(for: .seconds(backoff))
        guard !Task.isCancelled, !lifecycleBusy else { return }
        let ok = await reopenLink()
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
    /// A query (`expect`) skips lines until the one that answers it; a SET
    /// (`setParam`) skips lines that name another param, so a stray line
    /// does not become its reply and leave its echo and reply to the next
    /// exchange.
    private func transact(_ line: String, timeout: Double, expect: String?, setParam: String? = nil) async
        -> (response: String?, reachedWire: Bool)
    {
        guard await transport.isConnected() else {
            record("not sent, link is down: \(line)")
            mark(.missing, "send: link is down")
            return (nil, false)
        }
        var response: String?
        var gotLine = false
        var parsedOk = false
        do {
            try await transport.sendLine(line)
            record("send \(line)")
        } catch {
            record("send failed: \(line) (\(error))")
            mark(.missing, "send failed")
            // A write that timed out may already have put part or all of the
            // line on the wire. Report it as sent, so the SET is not queued
            // again: a second copy could repeat it, or follow a truncated
            // fragment on a serial line. The next poll shows the real state.
            return (nil, Self.isWriteTimeout(error))
        }
        try? await Task.sleep(for: .seconds(gap))
        var echoPending = model == .cp650
        var read = await nextLine(after: line, timeout: timeout, skipEcho: echoPending)
        if read.skippedEcho { gotLine = true; echoPending = false }
        response = read.line
        var pairs: [ResponsePair] = []
        if let setParam {
            var skipped = 0
            while let reply = response {
                let parsed = WireProtocol.parseResponse(model: model, text: reply)
                if parsed.isEmpty || parsed.contains(where: { sameScalars($0.param, setParam) }) { break }
                gotLine = true
                skipped += 1
                if skipped > Self.resyncMax {
                    record("gave up looking for \(setParam) after \(skipped) other lines")
                    response = nil
                    break
                }
                read = await nextLine(after: line, timeout: timeout, skipEcho: echoPending)
                if read.skippedEcho { echoPending = false }
                response = read.line
            }
        }
        if let reply = response {
            gotLine = true
            pairs = WireProtocol.parseResponse(model: model, text: reply)
            // A SET is answered by any line that parses, or an ACK; a query
            // only by the line that answers it (below).
            parsedOk = expect == nil && (!pairs.isEmpty || CP650Ack.isAck(reply))
        }
        if let expect, response != nil {
            var skipped = 0
            while !Self.answers(pairs, expect) {
                if skipped >= Self.resyncMax {
                    record("gave up looking for \(expect) after \(skipped) other lines")
                    response = nil
                    break
                }
                read = await nextLine(after: line, timeout: timeout, skipEcho: echoPending)
                if read.skippedEcho { gotLine = true; echoPending = false }
                response = read.line
                guard let reply = response else { break }
                gotLine = true
                skipped += 1
                pairs = WireProtocol.parseResponse(model: model, text: reply)
            }
            // Only the reply itself shows the processor is answering: stale
            // or unsolicited lines skipped on the way do not.
            parsedOk = response != nil && Self.answers(pairs, expect)
        }
        if parsedOk {
            mark(.ok)
            lastActivity = .now
        } else if !gotLine {
            mark(.missing, "no reply to \(line) within \(timeout) s")
        }
        return (response, true)
    }

    /// The next line read, past the CP650's one echo of `sent` when
    /// `skipEcho` (the echo can follow a stale line too, and a `KEY=?` echoed
    /// would otherwise parse as the pair KEY, "?"). Only one echo is skipped
    /// per exchange: the CP650's reply to a SET is the same text as its echo.
    private func nextLine(after sent: String, timeout: Double, skipEcho: Bool) async
        -> (line: String?, skippedEcho: Bool)
    {
        let read = await readLogged(timeout: timeout)
        guard skipEcho, let read, sameScalars(read, sent) else { return (read, false) }
        return (await readLogged(timeout: timeout), true)
    }

    /// A pair that answers the query for `param`: it names the param and
    /// carries a value, not a "?".
    private static func answers(_ pairs: [ResponsePair], _ param: String) -> Bool {
        pairs.contains { sameScalars($0.param, param) && !sameScalars($0.value, "?") }
    }

    /// The query line for `param` in the form the processor last answered.
    private func preferredQuery(_ param: String) throws(ProtocolError) -> String {
        let forms = try WireProtocol.queryForms(model: model, param: param)
        return forms[queryForm % forms.count]
    }

    /// No reply → not applied; a reply with no pair (an `ACK`, or anything
    /// else that does not parse) → applied; else it must name the param.
    private func confirmsSet(_ response: String?, _ param: String) -> Bool {
        guard let response else { return false }
        let pairs = WireProtocol.parseResponse(model: model, text: response)
        return pairs.isEmpty || pairs.contains { sameScalars($0.param, param) }
    }

    private func mark(_ newStatus: ProcessorStatus, _ why: String = "") {
        let changed = newStatus != state.status
        if changed { record("status \(state.status) -> \(newStatus)\(why.isEmpty ? "" : " (\(why))")") }
        state.mark(newStatus)
        if changed { statusContinuation.yield(newStatus) }
    }

    /// Send every event of the link (status changes with their reason, lines
    /// sent and received, timeouts, reconnects) to `sink`, for diagnostics.
    /// Pass nil to stop.
    public func setEventLog(_ sink: (@Sendable (String) -> Void)?) {
        eventLog = sink
    }

    private func record(_ text: @autoclosure () -> String) {
        eventLog?(text())
    }

    /// One line from the link, noted in the event log.
    private func readLogged(timeout: Double) async -> String? {
        let line = await transport.readLine(timeout: timeout)
        record("recv \(line ?? "<nothing within \(timeout) s>")")
        return line
    }

    // MARK: - One command in flight (FIFO)

    /// Close the transport while holding the command lock, so no command is
    /// mid-exchange on it (the transport allows one reader and one writer).
    private func closeLocked() async {
        await acquire()
        await closeTransport()
        release()
    }

    /// Any transport's failure that says its write timed out (`TransportFailure`).
    private static func isWriteTimeout(_ error: any Error) -> Bool {
        (error as? any TransportFailure)?.isWriteTimeout == true
    }

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

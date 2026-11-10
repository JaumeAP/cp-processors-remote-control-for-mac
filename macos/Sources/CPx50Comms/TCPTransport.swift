import Foundation
import Network

/// A TCP link to a processor over Network.framework.
///
/// 1. `connect()` opens a new connection within `connectTimeout`; only once it
///    is ready does it replace the current one (which is then closed). A
///    failed attempt leaves the current link as it was.
/// 2. `isConnected()` is true from a successful connect until `close()` or a
///    connection error (a reset): the peer closing its side does not change
///    it: a writer stays open after the peer's FIN.
/// 3. `peerClosed()` is true once the peer closed and every received byte has
///    been read.
/// 4. `sendLine` writes "<line>\n" with no validation of the content, and
///    fails with `notConnected` without an open link, `notASCII` (nothing
///    sent, link kept) for a non-ASCII line, `writeTimedOut` when the peer has
///    not taken the bytes within `writeTimeout` (the link stays open), or
///    `sendFailed` on a connection error (the link is then down).
/// 5. `readLine` follows `LineBuffer`; a reset makes every read return nil.
public actor TCPTransport: LineTransport {
    public enum Failure: Error, Sendable {
        case notConnected
        case notASCII
        case sendFailed(String)
        case writeTimedOut
    }

    public nonisolated let host: String
    public nonisolated let port: UInt16
    public nonisolated let connectTimeout: Double
    public nonisolated let writeTimeout: Double

    /// The established link; nil before connect and after close.
    private var connection: NWConnection?
    /// A connection error (reset) ended the link: it is closing.
    private var failed = false
    private var buffer = LineBuffer()
    private var dataWaiter: ResumeOnce<Bool>?
    private let networkQueue = DispatchQueue(label: "TCPTransport")

    public init(host: String, port: UInt16, connectTimeout: Double = 5.0,
                writeTimeout: Double = ProtocolTiming.writeTimeout) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
        self.writeTimeout = writeTimeout
    }

    deinit {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    // MARK: - LineTransport

    public func isConnected() -> Bool { connection != nil && !failed }

    public func peerClosed() -> Bool { connection != nil && !failed && buffer.atEOF && buffer.isEmpty }

    public func connect() async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let timeout = connectTimeout
        let ready: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let once = ResumeOnce(continuation)
                conn.stateUpdateHandler = { newState in
                    switch newState {
                    case .ready: once.resume(true)
                    case .failed, .waiting, .cancelled: once.resume(false)
                    default: break
                    }
                }
                conn.start(queue: networkQueue)
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    once.resume(false)
                }
                pendingConnect = (conn, once)
            }
        } onCancel: {
            Task { await self.cancelPendingConnect() }
        }
        if pendingConnect?.conn === conn { pendingConnect = nil }
        guard ready else {
            conn.stateUpdateHandler = nil
            conn.cancel()
            return false
        }
        if let old = connection {
            old.stateUpdateHandler = nil
            old.cancel()
        }
        connection = conn
        failed = false
        buffer = LineBuffer()
        wakeReader()
        conn.stateUpdateHandler = { [weak self] newState in
            Task { await self?.linkStateChanged(conn, newState) }
        }
        receiveNext(conn)
        return true
    }

    public func sendLine(_ line: String) async throws {
        guard let conn = connection, !failed else { throw Failure.notConnected }
        guard line.unicodeScalars.allSatisfy(\.isASCII) else { throw Failure.notASCII }
        let data = Data((line + "\n").utf8)
        let timeout = writeTimeout
        let result: Result<Void, Failure> = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            conn.send(content: data, completion: .contentProcessed { error in
                once.resume(error.map { .failure(.sendFailed("\($0)")) } ?? .success(()))
            })
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                once.resume(.failure(.writeTimedOut))
            }
        }
        if case .failure(let failure) = result {
            if case .sendFailed = failure, connection === conn { failed = true }
            throw failure
        }
    }

    public func readLine(timeout: Double) async -> String? {
        guard connection != nil else { return nil }
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            if failed { return nil }
            if case .done(let line) = buffer.read() { return line }
            guard !Task.isCancelled else { return nil }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero, await waitForData(remaining) else { return nil }
            guard connection != nil, !Task.isCancelled else { return nil }
        }
    }

    public func close() {
        if let conn = connection {
            connection = nil
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        failed = false
        buffer = LineBuffer()
        wakeReader()
    }

    // MARK: - Internals

    private var pendingConnect: (conn: NWConnection, once: ResumeOnce<Bool>)?

    private func cancelPendingConnect() {
        pendingConnect?.once.resume(false)
    }

    /// Wait until bytes, end of stream or an error arrive; false on timeout
    /// or cancellation.
    private func waitForData(_ remaining: Duration) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let once = ResumeOnce(continuation)
                dataWaiter = once
                Task {
                    try? await Task.sleep(for: remaining)
                    once.resume(false)
                }
            }
        } onCancel: {
            Task { await self.wakeReader() }
        }
    }

    private func wakeReader() {
        dataWaiter?.resume(true)
        dataWaiter = nil
    }

    private func linkStateChanged(_ conn: NWConnection, _ newState: NWConnection.State) {
        guard conn === connection else { return }
        // After the peer's FIN, a reset that follows (the peer answering a
        // send with RST) is not treated as a connection error: past end of
        // stream only `sendLine` takes the link down.
        if case .failed = newState, !buffer.atEOF {
            failed = true
            wakeReader()
        }
    }

    private func receiveNext(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { await self?.ingest(conn, data, isComplete: isComplete, error: error) }
        }
    }

    private func ingest(_ conn: NWConnection, _ data: Data?, isComplete: Bool, error: NWError?) {
        guard conn === connection else { return }
        if let data, !data.isEmpty { buffer.append(data) }
        if let error, !Self.isEndOfStream(error) {
            failed = true            // a reset: the connection is lost
        } else if isComplete || error != nil {
            buffer.markEOF()         // the peer's FIN: feed_eof
        } else {
            receiveNext(conn)
        }
        wakeReader()
    }

    /// A receive error that only means the peer closed cleanly.
    private static func isEndOfStream(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .ENODATA }
        return false
    }
}

/// A continuation that the first of several racers (a completion handler, a
/// timeout) resumes; later calls are no-ops and report false.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ value: T) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }
}

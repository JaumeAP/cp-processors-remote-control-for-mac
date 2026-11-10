import Darwin
import Foundation

/// A serial (RS-232 / USB-serial) link to a processor (the Swift port of
///
/// 1. `connect()` opens the device `O_RDWR | O_NOCTTY | O_NONBLOCK` (so a
///    port with its modem lines down cannot block the open), puts it in raw
///    mode and sets the baud rate (`configureRawSerial`); false if the open
/// 2. `isConnected()`, `peerClosed()`, `sendLine` and `readLine` behave as
///    `TCPTransport`'s: lines per `LineBuffer`; the other end closing (a pty
///    master closed, a cable pulled) is end of stream; the next failed write
///    then takes the link down.
/// 3. Each open link owns its descriptor through a `SerialLink`, which closes
///    it only once the read source has stopped and no write is running, so a
///    descriptor number reused by the next `connect()` is never touched by the
///    old link.
public actor SerialTransport: LineTransport {
    public enum Failure: Error, Sendable {
        case notConnected
        case notASCII
        case writeFailed(Int32)
        case writeTimedOut
    }

    public nonisolated let device: String
    public nonisolated let baudrate: Int
    public nonisolated let writeTimeout: Double

    /// The current link; nil before connect and after close.
    private var link: SerialLink?
    /// The asyncio writer is open and not closing.
    private var writerOpen = false
    private var buffer = LineBuffer()
    private var dataWaiter: ResumeOnce<Bool>?
    private let ioQueue = DispatchQueue(label: "SerialTransport")

    public init(device: String, baudrate: Int = 115200, writeTimeout: Double = ProtocolTiming.writeTimeout) {
        self.device = device
        self.baudrate = baudrate
        self.writeTimeout = writeTimeout
    }

    deinit {
        link?.shutDown()
    }

    // MARK: - LineTransport

    public func isConnected() -> Bool { writerOpen }

    public func peerClosed() -> Bool { link != nil && buffer.atEOF && buffer.isEmpty }

    public func connect() async -> Bool {
        let fd = Darwin.open(device, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        var info = stat()
        if fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
            Darwin.close(fd)
            return false
        }
        configureRawSerial(fd, baudrate: baudrate)
        close()
        let newLink = SerialLink(fd: fd, queue: ioQueue)
        link = newLink
        writerOpen = true
        buffer = LineBuffer()
        newLink.startReading { [weak self] in
            Task { await self?.takeInbox(from: newLink) }
        }
        return true
    }

    public func sendLine(_ line: String) async throws {
        guard writerOpen, let current = link else { throw Failure.notConnected }
        guard line.unicodeScalars.allSatisfy(\.isASCII) else { throw Failure.notASCII }
        let bytes = Array((line + "\n").utf8)
        let outcome = await current.write(bytes, timeout: writeTimeout)
        switch outcome {
        case .written:
            return
        case .closed:
            throw Failure.notConnected
        case .timedOut:
            throw Failure.writeTimedOut
        case .failed(let code):
            if link === current { writerOpen = false }
            throw Failure.writeFailed(code)
        }
    }

    public func readLine(timeout: Double) async -> String? {
        guard let current = link else { return nil }
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            if case .done(let line) = buffer.read() { return line }
            guard !Task.isCancelled else { return nil }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero, await waitForData(remaining) else { return nil }
            guard link === current, !Task.isCancelled else { return nil }
        }
    }

    public func close() {
        link?.shutDown()
        link = nil
        writerOpen = false
        buffer = LineBuffer()
        wakeReader()
    }

    // MARK: - Reading

    private func takeInbox(from source: SerialLink) {
        guard source === link else { return }
        let (data, eof) = source.takeInbox()
        buffer.append(data)
        if eof { buffer.markEOF() }
        wakeReader()
    }

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
}

/// One open serial descriptor and its read source. The descriptor is closed
/// only after `shutDown()`, once the source's cancel handler has run (so no
/// event handler can still read it) and no write is in progress.
private final class SerialLink: @unchecked Sendable {
    enum WriteOutcome: Sendable {
        case written, closed, timedOut, failed(Int32)
    }

    private let fd: Int32
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var inbox: [UInt8] = []
    private var eof = false
    private var shuttingDown = false
    private var readerStopped = true
    private var activeWrites = 0
    private var fdClosed = false

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func startReading(_ notify: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = self.fd
        var chunk = [UInt8](repeating: 0, count: 65536)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            while true {
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n > 0 {
                    self.locked { self.inbox.append(contentsOf: chunk[..<n]) }
                    continue
                }
                if n < 0, errno == EAGAIN || errno == EINTR { break }
                self.locked { self.eof = true }   // 0: end of stream; EIO: the other end is gone
                source?.cancel()
                break
            }
            notify()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            self.locked { self.readerStopped = true }
            self.closeIfIdle()
        }
        locked {
            self.source = source
            readerStopped = false
        }
        source.resume()
    }

    func takeInbox() -> ([UInt8], Bool) {
        locked {
            let out = (inbox, eof)
            inbox.removeAll()
            return out
        }
    }

    /// Stop reading and close the descriptor as soon as nothing uses it.
    func shutDown() {
        let pending: DispatchSourceRead? = locked {
            shuttingDown = true
            let s = source
            source = nil
            return s
        }
        pending?.cancel()
        closeIfIdle()
    }

    /// Write every byte, waiting for the descriptor to be writable, within
    /// `timeout` seconds. Runs on the link's queue, not the caller's thread.
    func write(_ bytes: [UInt8], timeout: Double) async -> WriteOutcome {
        let admitted: Bool = locked {
            guard !shuttingDown, !fdClosed else { return false }
            activeWrites += 1
            return true
        }
        guard admitted else { return .closed }
        let fd = self.fd
        let outcome: WriteOutcome = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: writeAll(fd, bytes, timeout: timeout))
            }
        }
        locked { activeWrites -= 1 }
        closeIfIdle()
        return outcome
    }

    private func closeIfIdle() {
        let close: Bool = locked {
            guard shuttingDown, readerStopped, activeWrites == 0, !fdClosed else { return false }
            fdClosed = true
            return true
        }
        if close { Darwin.close(fd) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Write every byte to a non-blocking fd within `timeout` seconds.
private func writeAll(_ fd: Int32, _ bytes: [UInt8], timeout: Double) -> SerialLink.WriteOutcome {
    let deadline = Date().addingTimeInterval(timeout)
    var offset = 0
    while offset < bytes.count {
        let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            offset += n
            continue
        }
        if n < 0, errno != EAGAIN, errno != EINTR { return .failed(errno) }
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else { return .timedOut }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        _ = poll(&p, 1, Int32(min(left * 1000, 100)))
    }
    return .written
}

/// `configure_raw` applies only these and ignores any other value silently.
let pythonTermiosBauds: Set<Int> = [0, 50, 75, 110, 134, 150, 200, 300, 600, 1200, 1800, 2400,
                                    4800, 9600, 19200, 38400, 57600, 115200, 230400]

/// a tty; errors are ignored.
///
/// them with `TCSAFLUSH`, which waits for pending output to drain and can
/// block forever when the other end does not read; the port applies them at
/// once (`TCSANOW`) and then discards pending input, the same outcome without
/// the hang (accepted difference, maintainer's decision 2026-11-09).
func configureRawSerial(_ fd: Int32, baudrate: Int?) {
    var mode = termios()
    guard tcgetattr(fd, &mode) == 0 else { return }
    // Each flag converted on its own: NOFLSH (0x80000000) is negative as an Int32.
    func flags(_ values: [some BinaryInteger]) -> tcflag_t {
        values.reduce(0) { $0 | tcflag_t(truncatingIfNeeded: $1) }
    }
    mode.c_iflag &= ~flags([IGNBRK, BRKINT, IGNPAR, PARMRK, INPCK, ISTRIP, INLCR, IGNCR, ICRNL,
                            IXON, IXANY, IXOFF])
    mode.c_oflag &= ~flags([OPOST])
    mode.c_cflag &= ~flags([PARENB, CSIZE])
    mode.c_cflag |= flags([CS8])
    mode.c_lflag &= ~(flags([ECHO, ECHOE, ECHOK, ECHONL, ICANON, IEXTEN, ISIG, TOSTOP])
                      | tcflag_t(truncatingIfNeeded: NOFLSH))
    withUnsafeMutableBytes(of: &mode.c_cc) { cc in
        cc[Int(VMIN)] = 1
        cc[Int(VTIME)] = 0
    }
    guard tcsetattr(fd, TCSANOW, &mode) == 0 else { return }
    _ = tcflush(fd, TCIFLUSH)
    guard let baudrate, pythonTermiosBauds.contains(baudrate) else { return }
    var speed = termios()
    guard tcgetattr(fd, &speed) == 0 else { return }
    _ = cfsetispeed(&speed, speed_t(baudrate))
    _ = cfsetospeed(&speed, speed_t(baudrate))
    _ = tcsetattr(fd, TCSANOW, &speed)
}

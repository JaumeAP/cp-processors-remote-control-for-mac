import Darwin
import Foundation
import Testing
@testable import CPx50Comms

// Tests that kill the mutants the first mutation run (macos/scripts/mutate.py)
// left alive in SerialTransport. They need no simulator: a pty plays the
// device, and /dev/null plays a device that is at end of stream at once.

/// A pty pair: the test plays the device on the master; the transport opens
/// the slave by path.
private struct MPty {
    let master: Int32
    let slave: Int32
    let path: String

    init() throws {
        var m: Int32 = -1
        var s: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&m, &s, &name, nil, nil) == 0 else { throw POSIXError(.ENODEV) }
        master = m
        slave = s
        path = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func write(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
    }

    /// The device goes away: the transport's side sees end of stream and
    /// fails its next write.
    func closeMaster() { Darwin.close(master) }

    func close() {
        Darwin.close(master)
        Darwin.close(slave)
    }
}

/// The descriptors this process holds open on `path`.
private func openDescriptors(on path: String) -> Int {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
    return names.compactMap(Int32.init).filter { fd in
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return false }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == path
    }.count
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SerialMutationTests {
    @Test func onlyAWriteTimeoutIsAWriteTimeout() {
        #expect(SerialTransport.Failure.writeTimedOut.isWriteTimeout)
        #expect(!SerialTransport.Failure.notConnected.isWriteTimeout)
        #expect(!SerialTransport.Failure.notASCII.isWriteTimeout)
        #expect(!SerialTransport.Failure.writeFailed(5).isWriteTimeout)
    }

    @Test func theLinkIsDownBeforeConnectAndAfterClose() async throws {
        let pty = try MPty()
        defer { pty.close() }
        let transport = SerialTransport(device: pty.path)
        #expect(await !transport.isConnected())
        #expect(await transport.connect())
        #expect(await transport.isConnected())
        await transport.close()
        #expect(await !transport.isConnected())
    }

    /// The other end counts as closed only with a link that has reached end
    /// of stream and has nothing left to read.
    @Test func peerClosedOnlyAfterTheOtherEndHasGone() async throws {
        let pty = try MPty()
        defer { Darwin.close(pty.slave) }
        let transport = SerialTransport(device: pty.path)
        #expect(await !transport.peerClosed(), "no link yet")
        #expect(await transport.connect())
        pty.write("a=1\n")
        #expect(await transport.readLine(timeout: 2) == "a=1")
        #expect(await !transport.peerClosed(), "link up, bytes read, no end of stream")
        pty.closeMaster()
        #expect(await transport.readLine(timeout: 2) == nil)
        #expect(await transport.peerClosed(), "the device is gone")
        await transport.close()
    }

    /// A device that reads as empty (read returns 0) is end of stream, and
    /// is seen as such.
    @Test func aDeviceThatReadsEmptyIsEndOfStream() async throws {
        let transport = SerialTransport(device: "/dev/null")
        #expect(await transport.connect())
        #expect(await transport.readLine(timeout: 2) == nil)
        #expect(await transport.peerClosed())
        await transport.close()
    }

    /// The link goes on reading after the first burst of bytes: running out
    /// of bytes for now (EAGAIN) is not end of stream.
    @Test func theLinkKeepsReadingAfterTheFirstBurst() async throws {
        let pty = try MPty()
        defer { pty.close() }
        let transport = SerialTransport(device: pty.path)
        #expect(await transport.connect())
        for round in 1...3 {
            pty.write("line\(round)\n")
            #expect(await transport.readLine(timeout: 2) == "line\(round)", "round \(round)")
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await transport.isConnected())
        #expect(await !transport.peerClosed())
        await transport.close()
    }

    /// A write to a device that is gone fails and takes the link down.
    @Test func aFailedWriteTakesTheLinkDown() async throws {
        let pty = try MPty()
        defer { Darwin.close(pty.slave) }
        let transport = SerialTransport(device: pty.path)
        #expect(await transport.connect())
        pty.closeMaster()
        try await Task.sleep(for: .milliseconds(100))
        var threw = false
        do { try await transport.sendLine("fader_level=1") } catch { threw = true }
        #expect(threw, "a write to a device that is gone must fail")
        #expect(await !transport.isConnected())
        await transport.close()
    }

    /// A port nobody reads fills up (EAGAIN): the write waits and times out,
    /// it is not a failed write.
    @Test func aFullPortTimesTheWriteOutInsteadOfFailingIt() async throws {
        let pty = try MPty()
        defer { pty.close() }
        let transport = SerialTransport(device: pty.path, writeTimeout: 0.3)
        #expect(await transport.connect())
        let big = String(repeating: "a", count: 1_000_000)
        do {
            try await transport.sendLine(big)
            Issue.record("the write finished into a port nobody reads")
        } catch let failure as SerialTransport.Failure {
            #expect(failure.isWriteTimeout, "\(failure)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
        await transport.close()
    }

    /// The port is put in raw mode at the chosen speed: 19200 is not the
    /// speed a fresh pty has.
    @Test func thePortIsPutInRawModeAtTheChosenSpeed() async throws {
        let pty = try MPty()
        defer { pty.close() }
        let transport = SerialTransport(device: pty.path, baudrate: 19200)
        #expect(await transport.connect())
        var mode = termios()
        #expect(tcgetattr(pty.slave, &mode) == 0)
        #expect(mode.c_lflag & tcflag_t(ICANON) == 0, "canonical mode must be off")
        #expect(mode.c_lflag & tcflag_t(ECHO) == 0, "echo must be off")
        #expect(mode.c_oflag & tcflag_t(OPOST) == 0, "output processing must be off")
        #expect(mode.c_cflag & tcflag_t(CSIZE) == tcflag_t(CS8), "8 data bits")
        #expect(mode.c_cflag & tcflag_t(CLOCAL) != 0, "modem lines are ignored")
        #expect(cfgetospeed(&mode) == speed_t(19200))
        #expect(cfgetispeed(&mode) == speed_t(19200))
        await transport.close()
    }

    /// Writing must not stop the descriptor from being closed: every connect,
    /// write and close leaves nothing open.
    @Test func aWriteDoesNotLeakTheDescriptor() async throws {
        let pty = try MPty()
        defer { pty.close() }
        let transport = SerialTransport(device: pty.path)
        #expect(await transport.connect())
        await transport.close()
        try await Task.sleep(for: .milliseconds(100))
        let before = openDescriptors(on: pty.path)
        for round in 0..<20 {
            #expect(await transport.connect())
            try await transport.sendLine("ping\(round)")
            await transport.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        let after = openDescriptors(on: pty.path)
        #expect(after == before, "\(after - before) descriptors left open by 20 connect/write/close cycles")
    }
}

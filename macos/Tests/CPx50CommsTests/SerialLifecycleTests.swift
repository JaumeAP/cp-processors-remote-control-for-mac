import Darwin
import Foundation
import Testing
@testable import CPx50Comms

/// A pty pair: the test plays the device on the master; the transport opens
/// the slave by path.
private struct SLPty {
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

    func close() {
        Darwin.close(master)
        Darwin.close(slave)
    }
}

/// Lifecycle regressions from the architecture review of the transports
/// slice (H1, H2).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SerialLifecycleTests {
    /// H1: a cancelled read returns at once, not at its deadline.
    @Test func cancelledReadReturnsAtOnce() async throws {
        let pty = try SLPty()
        defer { pty.close() }
        let transport = SerialTransport(device: pty.path)
        #expect(await transport.connect())
        let started = ContinuousClock.now
        let read = Task { await transport.readLine(timeout: 5) }
        try await Task.sleep(for: .milliseconds(50))
        read.cancel()
        #expect(await read.value == nil)
        #expect(ContinuousClock.now - started < .seconds(1), "a cancelled read waited for its deadline")
        await transport.close()
    }

    /// H2: close() then connect() reuses the descriptor number; the new link
    /// must get its own bytes, and the old link must not mark it down.
    @Test func reconnectOnTheSameDescriptorNumberKeepsTheNewLinkWhole() async throws {
        let pty = try SLPty()
        defer { pty.close() }
        let transport = SerialTransport(device: pty.path)
        for round in 0..<20 {
            #expect(await transport.connect(), "round \(round): connect")
            pty.write("line\(round)\n")
            #expect(await transport.readLine(timeout: 2) == "line\(round)", "round \(round): read")
            #expect(await transport.isConnected(), "round \(round): link marked down")
            try await transport.sendLine("ping\(round)")
            await transport.close()
        }
    }

    /// The descriptors this process holds open on `path` (other suites open
    /// sockets in parallel, so only this device's are counted).
    private func openDescriptors(on path: String) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return names.compactMap(Int32.init).filter { fd in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return false }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == path
        }.count
    }

    /// close() must close the descriptor: the read source's cancel handler,
    /// which closes it, used to find the link already released and do
    /// nothing, leaking one descriptor per close.
    @Test func closeReleasesTheDescriptor() async throws {
        let pty = try SLPty()
        defer { pty.close() }
        let transport = SerialTransport(device: pty.path)
        #expect(await transport.connect())
        await transport.close()
        try await Task.sleep(for: .milliseconds(100))
        let before = openDescriptors(on: pty.path)          // the test's own slave descriptor
        for _ in 0..<50 {
            #expect(await transport.connect())
            await transport.close()
        }
        try await Task.sleep(for: .milliseconds(300))      // the cancel handlers run on the link's queue
        let after = openDescriptors(on: pty.path)
        #expect(after == before, "\(after - before) descriptors left open by 50 connect/close cycles")
    }

    /// The processors speak 9600 baud; a rate the port cannot take is refused.
    @Test func theDefaultSpeedIs9600AndAnUnknownRateFailsTheConnect() async throws {
        let pty = try SLPty()
        defer { pty.close() }
        let transport = SerialTransport(device: pty.path)
        #expect(transport.baudrate == 9600)
        #expect(await transport.connect())
        var mode = termios()
        #expect(tcgetattr(pty.slave, &mode) == 0)
        #expect(cfgetospeed(&mode) == speed_t(9600), "the port must be set to 9600")
        await transport.close()
        for rate in [0, 12345] {
            #expect(await !SerialTransport(device: pty.path, baudrate: rate).connect(), "rate \(rate)")
        }
    }
}

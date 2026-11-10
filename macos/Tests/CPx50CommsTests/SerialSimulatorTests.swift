import Darwin
import Foundation
import Testing
@testable import CPx50Comms

/// Two ptys joined by a byte relay: the simulator serves one end, the client
/// opens the other by path, as a real serial cable would join them.
private final class PtyRelay: @unchecked Sendable {
    private let simMaster: Int32
    private let clientMaster: Int32
    /// The slave ends, held open for the whole test: closing them while the
    /// simulator and the client have not opened their paths yet can hang the
    /// pair up before anything is written.
    private let simSlave: Int32
    private let clientSlave: Int32
    let simPath: String
    let clientPath: String
    private let stopped = Locked(false)
    private let closed = Locked(false)
    private let finished = DispatchSemaphore(value: 0)
    private let thread: Thread

    init() throws {
        let (sm, ss, sp) = try PtyRelay.openPair()
        let (cm, cs, cp) = try PtyRelay.openPair()
        simMaster = sm
        clientMaster = cm
        simSlave = ss
        clientSlave = cs
        simPath = sp
        clientPath = cp
        let stopFlag = stopped
        let a = sm, b = cm
        let done = finished
        thread = Thread {
            PtyRelay.relay(a, b, stopFlag)
            done.signal()
        }
        thread.start()
    }

    private static func openPair() throws -> (Int32, Int32, String) {
        var m: Int32 = -1
        var s: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&m, &s, &name, nil, nil) == 0 else { throw POSIXError(.ENODEV) }
        let path = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (m, s, path)
    }

    /// Copy bytes both ways between the two masters until stopped.
    private static func relay(_ a: Int32, _ b: Int32, _ stop: Locked<Bool>) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !stop.withLock({ $0 }) {
            var fds = [pollfd(fd: a, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: b, events: Int16(POLLIN), revents: 0)]
            guard poll(&fds, 2, 50) > 0 else { continue }
            for (index, source) in [a, b].enumerated() where fds[index].revents & Int16(POLLIN) != 0 {
                let target = source == a ? b : a
                let count = read(source, &buffer, buffer.count)
                if count > 0 {
                    _ = buffer.withUnsafeBytes { write(target, $0.baseAddress, count) }
                }
            }
        }
    }

    func stop() {
        // Once: the test stops the relay and the deinit stops it again.
        guard !closed.withLock({ let was = $0; $0 = true; return was }) else { return }
        stopped.withLock { $0 = true }
        // Wait for the relay thread to leave poll() and read() before the
        // descriptors are closed, so a reused descriptor number is never read.
        _ = finished.wait(timeout: .now() + 2)
        close(simMaster)
        close(clientMaster)
        close(simSlave)
        close(clientSlave)
    }

    deinit { stop() }
}

@Suite(.serialized, .enabled(if: simulatorPath != nil, "needs CPSIM_BIN (the simulator)"))
struct SerialSimulatorTests {
    /// The CP850 over a serial line: the client connects, reads, sets and
    /// reads back, through the real serial transport and the simulator.
    @Test
    func cp850OverASerialLine() async throws {
        let path = try #require(simulatorPath)
        let relay = try PtyRelay()
        defer { relay.stop() }

        let sim = Process()
        sim.executableURL = URL(fileURLWithPath: path)
        sim.arguments = ["--model", "CP850", "--port", "0", "--serial", relay.simPath, "--profile"]
        sim.standardOutput = FileHandle.nullDevice
        sim.standardError = FileHandle.nullDevice
        try sim.run()
        defer { stopSimulatorProcess(sim) }

        let cp = DolbyCP.overSerial(device: relay.clientPath, model: .cp850)
        #expect(await cp.connect())
        // The simulator opens its end a moment after it starts: ask until it answers.
        #expect(await eventually(10) {
            let value = try? await cp.get("sys.fader", timeout: 2)
            return value == "70"
        })
        #expect(try await cp.set("sys.fader", 45))
        #expect(await eventually(10) {
            let value = try? await cp.get("sys.fader", timeout: 2)
            return value == "45"
        })
        await cp.disconnect()
    }
}

import Darwin
import Foundation
import Testing
@testable import CPx50Comms

/// A one-shot TCP listener on loopback that the test drives by hand.
private final class Listener: @unchecked Sendable {
    let fd: Int32
    let port: UInt16

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, length) }
        }
        guard bound == 0, listen(socketFD, 4) == 0 else {
            close(socketFD)
            throw POSIXError(.EADDRINUSE)
        }
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        fd = socketFD
        port = UInt16(bigEndian: address.sin_port)
    }

    /// Accept one connection (blocking, so call it off the main actor).
    func accept() -> Int32 { Darwin.accept(fd, nil, nil) }

    /// Close `connection` with a reset (RST), not a FIN.
    static func reset(_ connection: Int32) {
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(connection, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        close(connection)
    }

    deinit { close(fd) }
}

/// The failure paths of the TCP link and of `getList` that no test reached
/// (the coverage report of the review).
@Suite(.serialized) struct NetworkFailureTests {
    /// A reset from the peer takes the link down, and a send then fails.
    @Test func aResetTakesTheLinkDownAndASendFails() async throws {
        let listener = try Listener()
        let transport = TCPTransport(host: "127.0.0.1", port: listener.port)
        async let accepted = Task.detached { listener.accept() }.value
        #expect(await transport.connect())
        let connection = await accepted
        #expect(connection >= 0)
        Listener.reset(connection)
        #expect(await eventually { await !transport.isConnected() }, "a reset must take the link down")
        #expect(await transport.readLine(timeout: 0.2) == nil)
        await #expect(throws: TCPTransport.Failure.self) { try await transport.sendLine("mute=?") }
        await transport.close()
    }

    /// A connect cancelled while it waits returns false at once, not at its
    /// timeout.
    @Test func aConnectCancelledWhileWaitingReturnsAtOnce() async throws {
        // 192.0.2.0/24 is reserved for documentation: nothing answers there.
        let transport = TCPTransport(host: "192.0.2.1", port: 61412, connectTimeout: 10)
        let started = ContinuousClock.now
        let attempt = Task { await transport.connect() }
        try await Task.sleep(for: .milliseconds(100))
        attempt.cancel()
        #expect(await attempt.value == false)
        #expect(ContinuousClock.now - started < .seconds(2), "the cancelled connect waited for its timeout")
        #expect(await !transport.isConnected())
    }
}

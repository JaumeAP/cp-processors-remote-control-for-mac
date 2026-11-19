import Foundation
import Testing
@testable import CPx50Comms

/// A serial connect that fails says why (permission, busy, missing device),
/// as `TCPTransport` does, so the connection log is not only "connect failed".
struct SerialConnectFailureTests {
    @Test func aMissingDeviceSaysWhy() async {
        let transport = SerialTransport(device: "/dev/cu.does-not-exist")
        #expect(await transport.connect() == false)
        let reason = await transport.lastConnectFailure()
        #expect(reason?.contains("/dev/cu.does-not-exist") == true, "\(reason ?? "nil")")
        #expect(reason?.contains("errno") == true)
    }

    @Test func aDirectorySaysSo() async {
        let transport = SerialTransport(device: "/tmp")
        #expect(await transport.connect() == false)
        #expect(await transport.lastConnectFailure()?.contains("directory") == true)
    }

    @Test func aBadBaudRateSaysSo() async {
        let transport = SerialTransport(device: "/dev/null", baudrate: 12345)
        #expect(await transport.connect() == false)
        #expect(await transport.lastConnectFailure()?.contains("baud") == true)
    }
}

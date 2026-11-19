/// A newline-framed link to a processor: the interface `DolbyCP` drives
/// (`TCPTransport`, `SerialTransport`). One reader and one writer at a time.
public protocol LineTransport: Sendable {
    /// True while the link is open (it may still have been closed by the peer).
    func isConnected() async -> Bool
    /// True once the peer has closed its side.
    func peerClosed() async -> Bool
    /// Open the link; true on success.
    func connect() async -> Bool
    /// Send one line (the line end is added: LF, or CR LF for a CP650). Throws when it was not sent; the
    /// link is then lost, except after a write timeout or a non-ASCII line.
    func sendLine(_ line: String) async throws
    /// The next complete line, or nil on timeout, end of stream or no link.
    func readLine(timeout: Double) async -> String?
    /// Close the link (idempotent).
    func close() async
    /// Why the last `connect()` failed, for the connection log; nil when it
    /// succeeded or the transport does not say.
    func lastConnectFailure() async -> String?
}

extension LineTransport {
    public func lastConnectFailure() async -> String? { nil }
}

/// An error a `sendLine` can throw that may say the write timed out: part or
/// all of the line may then be on the wire, so `DolbyCP` does not send the
/// SET again. Any transport's failure type can adopt it.
public protocol TransportFailure: Error {
    /// The write timed out (the bytes may have gone out).
    var isWriteTimeout: Bool { get }
}

/// A newline-framed link to a processor: the interface `DolbyCP` drives
/// (`TCPTransport`, `SerialTransport`). One reader and one writer at a time.
public protocol LineTransport: Sendable {
    /// True while the link is open (it may still have been closed by the peer).
    func isConnected() async -> Bool
    /// True once the peer has closed its side.
    func peerClosed() async -> Bool
    /// Open the link; true on success.
    func connect() async -> Bool
    /// Send one line (the newline is added). Throws when it was not sent; the
    /// link is then lost, except after a write timeout or a non-ASCII line.
    func sendLine(_ line: String) async throws
    /// The next complete line, or nil on timeout, end of stream or no link.
    func readLine(timeout: Double) async -> String?
    /// Close the link (idempotent).
    func close() async
}

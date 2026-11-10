// A plain-text log of what the app and its link to the processor do, for
// finding why a connection was lost. One line per event, with the time to the
// millisecond. It records the lines exchanged with the processor, the status
// changes with their reason, and the window and focus changes of the app. It
// never records anything else about the Mac or the user.

import Foundation

final class ConnectionLog: @unchecked Sendable {
    /// The log of the running app: `~/Library/Logs/CP Remote/connection.log`.
    static let shared = ConnectionLog()

    let url: URL
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "cpremote.connection-log")
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// `directory` and `maximumBytes` are for tests; the defaults are the real
    /// ones. When the file grows past `maximumBytes` it becomes
    /// `connection.log.1` (replacing the older one) and a new file starts, so
    /// the log never takes more than twice that.
    init(directory: URL? = nil, maximumBytes: Int = 1_000_000) {
        let folder = directory ?? FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/CP Remote", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("connection.log")
        self.maximumBytes = maximumBytes
    }

    /// Append one line. Never blocks the caller and never throws.
    func write(_ text: String) {
        let line = "\(formatter.string(from: Date())) \(text)\n"
        queue.async { [self] in append(line) }
    }

    /// Wait until every line written so far is on disk (for tests and quit).
    func flush() {
        queue.sync {}
    }

    private func append(_ line: String) {
        let fileManager = FileManager.default
        if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > maximumBytes {
            let older = url.appendingPathExtension("1")
            try? fileManager.removeItem(at: older)
            try? fileManager.moveItem(at: url, to: older)
        }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

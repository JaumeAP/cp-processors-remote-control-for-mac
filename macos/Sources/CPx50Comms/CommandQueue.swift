/// One SET waiting to go on the wire.
public struct PendingSet: Sendable {
    public let param: String
    public let value: WireValue
    public let timeout: Double

    public init(param: String, value: WireValue, timeout: Double = 0.5) {
        self.param = param
        self.value = value
        self.timeout = timeout
    }
}

extension PendingSet: Equatable {
    /// Exact equality: the param and string values compare by Unicode
    public static func == (a: PendingSet, b: PendingSet) -> Bool {
        sameScalars(a.param, b.param) && a.value.isIdentical(to: b.value) && a.timeout == b.timeout
    }
}

/// maintainer decided: the client never queues a GET).
///
/// 1. A SET for a param already queued replaces that entry in place, value
///    and timeout, keeping its FIFO position.
/// 2. Past `maxSize` the oldest entry is dropped, so the latest intent wins.
/// 3. A SET whose send never reached the wire goes back to the head, unless
///    a SET for the same param is queued (the newer value wins and the retry
///    is dropped); over capacity, the newest tail is dropped instead.
/// 4. `inflight` records the one command being sent; queue operations never
///    touch it.
///
/// Kelvin sign in "\u{212A}EY" is not "KEY", and NFC and NFD "café" are two
/// params.
public struct CommandQueue: Sendable {
    public static let defaultMaxSize = 10

    public let maxSize: Int
    public private(set) var items: [PendingSet] = []
    public private(set) var inflight: PendingSet?

    public init(maxSize: Int = CommandQueue.defaultMaxSize) {
        self.maxSize = maxSize
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
    public var hasInflight: Bool { inflight != nil }

    public mutating func enqueue(_ command: PendingSet) {
        if let index = items.firstIndex(where: { sameScalars($0.param, command.param) }) {
            items[index] = command
            return
        }
        items.append(command)
        if items.count > maxSize { items.removeFirst() }
    }

    public mutating func dequeue() -> PendingSet? {
        items.isEmpty ? nil : items.removeFirst()
    }

    public mutating func requeueFront(_ command: PendingSet) {
        if items.contains(where: { sameScalars($0.param, command.param) }) { return }
        items.insert(command, at: 0)
        if items.count > maxSize { items.removeLast() }
    }

    public mutating func setInflight(_ command: PendingSet) {
        inflight = command
    }

    public mutating func clearInflight() {
        inflight = nil
    }
}

func sameScalars(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.elementsEqual(b.unicodeScalars)
}

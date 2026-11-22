// One control link to a processor, through the released cpseries library
// (cpseries-release, its plain-C API). The library blocks on the network, so
// every call runs on the link's own serial queue, never on the main actor,
// and the handle is touched only on that queue.

import CPSeries
import Foundation

final class ProcessorLink: @unchecked Sendable {
    let host: String
    let port: UInt16
    let model: ProcessorModel

    private let queue = DispatchQueue(label: "cpremote.processor-link")
    /// The cpseries handle; read and written only on `queue`.
    private var handle: OpaquePointer?

    /// `port` nil: the model's own port. The link re-opens itself inside a
    /// query or a send when it finds the connection dropped.
    init(host: String, port: UInt16?, model: ProcessorModel) {
        self.host = host
        self.port = port ?? model.defaultPort
        self.model = model
        var options = cpseries_options()
        cpseries_options_default(&options)
        options.auto_reconnect = 1
        handle = cpseries_new(host, Int32(self.port), model.rawValue, &options)
    }

    deinit {
        // Freed on the queue, after any call still waiting there.
        nonisolated(unsafe) let handle = handle
        queue.async { cpseries_free(handle) }
    }

    /// Run `body` on the link's queue with the handle; `fallback` when the
    /// handle could not be made (an address the library refuses).
    private func perform<T: Sendable>(_ fallback: T, _ body: @escaping @Sendable (OpaquePointer) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: handle.map(body) ?? fallback)
            }
        }
    }

    /// Open the link. True when it is up.
    func connect() async -> Bool {
        await perform(false) { cpseries_connect($0) == 1 }
    }

    /// Close the link and open it again, keeping queued sends.
    func reconnect() async -> Bool {
        await perform(false) { cpseries_reconnect($0) == 1 }
    }

    func disconnect() async {
        await perform(()) { cpseries_disconnect($0) }
    }

    /// The link status: one of the CPSERIES_* values.
    var status: Int32 {
        get async { await perform(Int32(CPSERIES_MISSING)) { cpseries_status($0) } }
    }

    /// Ask for `param` and wait for its value; nil when there is none (a
    /// timeout, `error`, a lost link). `timeout` 0: the library's own.
    func get(_ param: String, timeout: Double = 0) async -> String? {
        await perform(nil) { handle in
            var size = 256
            while true {
                var buffer = [CChar](repeating: 0, count: size)
                let length = Int(cpseries_get(handle, param, &buffer, size, timeout))
                guard length >= 0 else { return nil }
                if length < size {
                    return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                size = length + 1
            }
        }
    }

    /// Send `param` = `value` and wait until it is through. False when the
    /// link was down and could not be re-opened, or the value cannot be sent.
    func set(_ param: String, _ value: Int) async -> Bool {
        await perform(false) { handle in
            guard cpseries_set_int(handle, param, Int64(value)) == 1 else { return false }
            cpseries_run(handle)
            return true
        }
    }

    func set(_ param: String, _ value: String) async -> Bool {
        await perform(false) { handle in
            guard cpseries_set_text(handle, param, value) == 1 else { return false }
            cpseries_run(handle)
            return true
        }
    }

    /// The text of the last error on the link, for the log.
    var lastError: String {
        get async { await perform("") { String(cString: cpseries_last_error($0)) } }
    }
}

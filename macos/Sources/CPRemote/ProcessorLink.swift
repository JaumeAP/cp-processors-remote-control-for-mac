// One control link to a processor, through the released cpx50comms library
// (cpseries-release, its plain-C API). The library blocks on the network, so
// every call runs on the link's own serial queue, never on the main actor,
// and the handle is touched only on that queue.
//
// Only the cpx50comms library is imported (the CPSeriesC module). When that
// module is not available to the build, the link compiles to a stub: it never
// connects and every query returns nothing.

import Foundation

#if canImport(CPSeriesC)
    import CPSeriesC
#endif

#if canImport(CPSeriesC)

    final class ProcessorLink: ControlLink, @unchecked Sendable {
        let host: String
        let port: UInt16
        let model: ProcessorModel

        private let queue = DispatchQueue(label: "cpremote.processor-link")
        /// The cpx50comms handle; read and written only on `queue`.
        private var handle: OpaquePointer?

        /// `port` nil: the model's own port. The link re-opens itself inside a
        /// query or a send when it finds the connection dropped.
        init(host: String, port: UInt16?, model: ProcessorModel) {
            self.host = host
            self.port = port ?? model.defaultPort
            self.model = model
            var options = cpx50comms_options()
            cpx50comms_options_default(&options)
            options.auto_reconnect = 1
            handle = cpx50comms_new(host, Int32(self.port), model.rawValue, &options)
        }

        deinit {
            // Freed on the queue, after any call still waiting there.
            nonisolated(unsafe) let handle = handle
            queue.async { cpx50comms_free(handle) }
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
            await perform(false) { cpx50comms_connect($0) == 1 }
        }

        /// Close the link and open it again, keeping queued sends.
        func reconnect() async -> Bool {
            await perform(false) { cpx50comms_reconnect($0) == 1 }
        }

        func disconnect() async {
            await perform(()) { cpx50comms_disconnect($0) }
        }

        /// Ask for `param` and wait for its value; nil when there is none (a
        /// timeout, `error`, a lost link). `timeout` 0: the library's own.
        func get(_ param: String, timeout: Double) async -> String? {
            await perform(nil) { handle in
                var size = 256
                while true {
                    var buffer = [CChar](repeating: 0, count: size)
                    let length = Int(cpx50comms_get(handle, param, &buffer, size, timeout))
                    guard length >= 0 else { return nil }
                    if length < size {
                        // The processor sends ASCII; a reply that is not UTF-8 reads as "".
                        let bytes = buffer.prefix(length).map { UInt8(bitPattern: $0) }
                        return String(bytes: bytes, encoding: .utf8) ?? ""
                    }
                    size = length + 1
                }
            }
        }

        /// Send `param` = `value` and wait until it is through. False when the
        /// link is not up (nothing is queued then, so nothing is sent later), or
        /// the value cannot be sent.
        func set(_ param: String, _ value: Int) async -> Bool {
            await perform(false) { handle in
                guard cpx50comms_status(handle) == Int32(CPX50COMMS_OK) else { return false }
                guard cpx50comms_set_int(handle, param, Int64(value)) == 1 else { return false }
                cpx50comms_run(handle)
                return true
            }
        }

        func set(_ param: String, _ value: String) async -> Bool {
            await perform(false) { handle in
                guard cpx50comms_status(handle) == Int32(CPX50COMMS_OK) else { return false }
                guard cpx50comms_set_text(handle, param, value) == 1 else { return false }
                cpx50comms_run(handle)
                return true
            }
        }

        /// The text of the last error on the link, for the log.
        var lastError: String {
            get async { await perform("") { String(cString: cpx50comms_last_error($0)) } }
        }
    }

#else

    /// Stub used when the cpx50comms library is not available to the build.
    final class ProcessorLink: ControlLink, @unchecked Sendable {
        let host: String
        let port: UInt16
        let model: ProcessorModel

        init(host: String, port: UInt16?, model: ProcessorModel) {
            self.host = host
            self.port = port ?? model.defaultPort
            self.model = model
        }

        func connect() async -> Bool { false }
        func reconnect() async -> Bool { false }
        func disconnect() async {}
        func get(_ param: String, timeout: Double) async -> String? { nil }
        func set(_ param: String, _ value: Int) async -> Bool { false }
        func set(_ param: String, _ value: String) async -> Bool { false }
        var lastError: String { get async { "cpx50comms library not available" } }
    }

#endif

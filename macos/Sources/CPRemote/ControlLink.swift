// What the model needs from a control link to a processor. `ProcessorLink`
// is the real one, over the cpx50comms library; tests give the model a fake
// one, so the poll and the sends can be checked without a processor.

import Foundation

protocol ControlLink: AnyObject, Sendable {
    var host: String { get }
    var port: UInt16 { get }
    var model: ProcessorModel { get }

    /// Open the link. True when it is up.
    func connect() async -> Bool
    /// Close the link and open it again, keeping queued sends.
    func reconnect() async -> Bool
    func disconnect() async
    /// Ask for `param` and wait for its value; nil when there is none.
    /// `timeout` 0: the link's own.
    func get(_ param: String, timeout: Double) async -> String?
    /// Send `param` = `value`. False when it could not be sent.
    func set(_ param: String, _ value: Int) async -> Bool
    func set(_ param: String, _ value: String) async -> Bool
    /// The text of the last error on the link, for the log.
    var lastError: String { get async }
}

extension ControlLink {
    /// Ask for `param` with the link's own timeout.
    func get(_ param: String) async -> String? { await get(param, timeout: 0) }
}

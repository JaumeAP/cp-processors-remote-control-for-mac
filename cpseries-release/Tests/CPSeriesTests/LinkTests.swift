// Checks that the prebuilt library links and answers through its C API.
// No network: a client is created and freed without connecting.
import CPSeries
import Testing

@Test func defaultPortsMatchTheModels() {
    #expect(cpx50comms_default_port("CP650") == 61412)
    #expect(cpx50comms_default_port("CP750") == 61408)
    #expect(cpx50comms_default_port("CP950A") == 61408)
    #expect(cpx50comms_default_port("CP999") == -1)
}

@Test func clientIsCreatedWithoutConnecting() {
    let client = cpx50comms_new("127.0.0.1", 0, "CP750", nil)
    #expect(client != nil)
    #expect(cpx50comms_queued(client) == 0)
    cpx50comms_free(client)
    #expect(cpx50comms_new("127.0.0.1", 0, "CP999", nil) == nil)
}

@Test func statusNamesAreKnown() {
    #expect(String(cString: cpx50comms_status_name(Int32(CPX50COMMS_OK))) == "OK")
    #expect(String(cString: cpx50comms_status_name(Int32(CPX50COMMS_MISSING))) == "MISSING")
}

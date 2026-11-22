// Checks that the prebuilt library links and answers through its C API.
// No network: a client is created and freed without connecting.
import CPSeries
import Testing

@Test func defaultPortsMatchTheModels() {
    #expect(cpseries_default_port("CP650") == 61412)
    #expect(cpseries_default_port("CP750") == 61408)
    #expect(cpseries_default_port("CP950A") == 61408)
    #expect(cpseries_default_port("CP999") == -1)
}

@Test func clientIsCreatedWithoutConnecting() {
    let client = cpseries_new("127.0.0.1", 0, "CP750", nil)
    #expect(client != nil)
    #expect(cpseries_queued(client) == 0)
    cpseries_free(client)
    #expect(cpseries_new("127.0.0.1", 0, "CP999", nil) == nil)
}

@Test func statusNamesAreKnown() {
    #expect(String(cString: cpseries_status_name(Int32(CPSERIES_OK))) == "OK")
    #expect(String(cString: cpseries_status_name(Int32(CPSERIES_MISSING))) == "MISSING")
}

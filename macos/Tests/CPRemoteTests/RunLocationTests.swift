import Foundation
import Testing

@testable import CPRemote

/// The Move to Applications alert: macOS ties the Local Network permission to
/// where the app is, so a copy run from the disk image or translocated from
/// Downloads is told to move.
struct RunLocationTests {
    @Test(arguments: [
        "/Volumes/CP Remote 1.0.16/CPRemote.app",
        "/private/var/folders/xy/abc/T/AppTranslocation/1234-5678/d/CPRemote.app",
    ])
    func outsideApplications(_ path: String) {
        #expect(RemoteModel.runsOutsideApplications(path))
    }

    @Test(arguments: ["/Applications/CPRemote.app", "/Users/someone/Applications/CPRemote.app"])
    func inApplications(_ path: String) {
        #expect(!RemoteModel.runsOutsideApplications(path))
    }
}

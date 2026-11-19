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

    @Test @MainActor func theSettingsLinkNamesTheLocalNetworkPane() {
        #expect(RemoteModel.localNetworkSettings.absoluteString.hasSuffix("?Privacy_LocalNetwork"))
    }
}

/// The Local Network help says what is true for the macOS it runs on.
struct LocalNetworkGuidanceTests {
    private func version(_ major: Int, _ minor: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }

    @Test(arguments: [15, 26])
    @MainActor func beforeTheAddButtonTheNoteSaysToReopenTheApp(_ major: Int) {
        let guidance = LocalNetworkHelp.guidance(for: version(major))
        #expect(guidance.note.contains("open it again from Applications"))
        #expect(!guidance.steps.contains { $0.contains("click +") })
    }

    @Test @MainActor func fromMacOS27_2TheStepsOfferTheAddButton() {
        #expect(LocalNetworkHelp.guidance(for: version(27, 1)).steps.count == 3)
        for v in [version(27, 2), version(28)] {
            let guidance = LocalNetworkHelp.guidance(for: v)
            #expect(guidance.steps.contains { $0.contains("click +") })
            #expect(!guidance.note.contains("open it again from Applications"))
        }
    }

    @Test @MainActor func everyVersionKeepsTheThreeMainSteps() {
        for v in [version(15), version(26), version(27, 2)] {
            let steps = LocalNetworkHelp.guidance(for: v).steps
            #expect(steps.first?.hasPrefix("1.") == true)
            #expect(steps.last?.hasPrefix("3.") == true)
        }
    }
}

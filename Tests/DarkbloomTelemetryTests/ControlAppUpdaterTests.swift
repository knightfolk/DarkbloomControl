import Foundation
import Testing
@testable import DarkbloomMonitor

@MainActor
struct ControlAppUpdaterTests {
    @Test func rejectsIncompleteOrInsecureConfiguration() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        #expect(ControlAppUpdater.hasValidConfiguration(feed: "https://example.com/appcast.xml", publicKey: key))
        for feed in [nil, "", "http://example.com/appcast.xml", "file:///tmp/appcast.xml", "https://user:secret@example.com/appcast.xml"] as [String?] {
            #expect(!ControlAppUpdater.hasValidConfiguration(feed: feed, publicKey: key))
        }
        for invalid in [nil, "", "not-a-key", Data(repeating: 0, count: 31).base64EncodedString()] as [String?] {
            #expect(!ControlAppUpdater.hasValidConfiguration(feed: "https://example.com/appcast.xml", publicKey: invalid))
        }
    }

    @Test func unconfiguredUpdaterCannotEnableOrInstallUpdates() {
        let updater = ControlAppUpdater()
        updater.setAutomaticChecks(true)
        updater.setAutomaticInstall(true)
        updater.check()
        #expect(!updater.isConfigured)
        #expect(!updater.canCheck)
        #expect(!updater.automaticChecks)
        #expect(!updater.automaticInstall)
    }
}

import Foundation
import Testing
@testable import DarkbloomMonitor

@Suite("Monitor app identity")
struct MonitorApplicationIdentityTests {
    @Test("the production app keeps its existing support and lock paths")
    func productionPathsStayStable() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let support = MonitorApplicationIdentity.applicationSupportDirectory(
            homeDirectory: home,
            bundleIdentifier: "dev.darkbloom.monitor"
        )
        #expect(support.path == "/Users/example/Library/Application Support/Darkbloom Monitor")
        #expect(SingleInstanceGuard.defaultLockURL(
            homeDirectory: home,
            bundleIdentifier: "dev.darkbloom.monitor"
        ).path == "/Users/example/Library/Application Support/Darkbloom Monitor/darkbloom-monitor.lock")
        #expect(MonitorApplicationIdentity.applicationSupportDirectory(
            homeDirectory: home,
            bundleIdentifier: nil
        ) == support)
    }

    @Test("the beta app gets independent history storage and a separate lock")
    func betaPathsAreIsolated() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let betaSupport = MonitorApplicationIdentity.applicationSupportDirectory(
            homeDirectory: home,
            bundleIdentifier: "dev.darkbloom.monitor.beta"
        )
        let betaLock = SingleInstanceGuard.defaultLockURL(
            homeDirectory: home,
            bundleIdentifier: "dev.darkbloom.monitor.beta"
        )

        #expect(betaSupport.path == "/Users/example/Library/Application Support/Darkbloom Monitor (dev.darkbloom.monitor.beta)")
        #expect(betaLock.path == betaSupport.appendingPathComponent("darkbloom-monitor.lock").path)
        #expect(betaSupport != MonitorApplicationIdentity.applicationSupportDirectory(
            homeDirectory: home,
            bundleIdentifier: "dev.darkbloom.monitor"
        ))
        #expect(betaLock != SingleInstanceGuard.defaultLockURL(
            homeDirectory: home,
            bundleIdentifier: "dev.darkbloom.monitor"
        ))
    }
}

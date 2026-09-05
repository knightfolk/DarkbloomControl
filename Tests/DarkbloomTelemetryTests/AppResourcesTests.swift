import Foundation
import Testing
@testable import DarkbloomMonitor

@Suite("Relocatable app resources")
struct AppResourcesTests {
    @Test("packaged resource wins without evaluating development fallback")
    func packagedResource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Review.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        let module = resources.appendingPathComponent("DarkbloomMonitor_DarkbloomMonitor.bundle")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.resources", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let asset = module.appendingPathComponent("marker.svg")
        try Data("packaged-marker".utf8).write(to: asset)
        let bundle = try #require(Bundle(url: app))
        var fallbackCalled = false
        let result = AppResources.url(named: "marker", extension: "svg", appBundle: bundle) {
            fallbackCalled = true
            return Bundle.main
        }
        #expect(result?.standardizedFileURL == asset.standardizedFileURL)
        #expect(fallbackCalled == false)
    }

    @Test("development fallback supplies resources and missing assets return nil")
    func developmentFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let module = root.appendingPathComponent("Development.bundle")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        let asset = module.appendingPathComponent("marker.svg")
        try Data("development-marker".utf8).write(to: asset)
        let bundle = try #require(Bundle(url: module))
        #expect(AppResources.url(named: "marker", extension: "svg", developmentBundle: { bundle }) == asset)
        #expect(AppResources.url(named: "missing", extension: "svg", developmentBundle: { bundle }) == nil)
    }
}

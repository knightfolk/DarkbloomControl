import Foundation

enum AppResources {
    /// A packaged app must not evaluate SwiftPM's development accessor, which
    /// can terminate the process when the original build directory is absent.
    static func url(
        named name: String,
        extension fileExtension: String,
        appBundle: Bundle = .main,
        developmentBundle: () -> Bundle = { Bundle.module }
    ) -> URL? {
        if let resources = appBundle.resourceURL,
           let packaged = Bundle(url: resources.appendingPathComponent("DarkbloomMonitor_DarkbloomMonitor.bundle")),
           let asset = packaged.url(forResource: name, withExtension: fileExtension) {
            return asset
        }
        return developmentBundle().url(forResource: name, withExtension: fileExtension)
    }
}

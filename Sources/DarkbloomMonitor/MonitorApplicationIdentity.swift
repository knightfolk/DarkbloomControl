import Foundation

/// Per-bundle display and local-storage identity. The production bundle keeps
/// its historical name and paths; review variants get isolated preferences,
/// history files, and single-instance locks while observing the same provider.
enum MonitorApplicationIdentity {
    static let productionBundleIdentifier = "dev.darkbloom.monitor"

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "Darkbloom Control"
    }

    static func applicationSupportDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL {
        let directoryName: String
        if let bundleIdentifier,
           !bundleIdentifier.isEmpty,
           bundleIdentifier != productionBundleIdentifier {
            // Bundle identifiers are reverse-DNS names. Replace path separators
            // defensively before using one as a folder namespace.
            let namespace = bundleIdentifier
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "\\", with: "-")
            directoryName = "Darkbloom Monitor (\(namespace))"
        } else {
            directoryName = "Darkbloom Monitor"
        }

        return homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }
}

import Foundation

/// One compatibility factor only. Never authorizes loading or model eviction.
public enum CatalogRAMFit: Equatable, Sendable {
    case unavailable
    case belowMinimum
    case minimumMet

    public static func evaluate(modelID: String, metadata: CatalogModel?, metadataIsCurrent: Bool,
                                installedMemoryBytes: UInt64) -> Self {
        guard let metadata, metadata.id == modelID, metadataIsCurrent,
              metadata.minimumRAMGB > 0, installedMemoryBytes > 0 else { return .unavailable }
        // Match the provider's GiB-based memory convention; this is installed
        // physical memory, not reclaimable pages, swap or staging headroom.
        let installedGiB = Double(installedMemoryBytes) / 1_073_741_824
        return installedGiB >= Double(metadata.minimumRAMGB) ? .minimumMet : .belowMinimum
    }
}

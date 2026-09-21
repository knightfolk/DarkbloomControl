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

/// Compatibility with catalog-declared provider features is separate from
/// installed-memory fit. A chip name or model family is not runtime evidence
/// that an optional provider capability (such as MLX NAX) is active.
public enum CatalogProviderCapabilityFit: Equatable, Sendable {
    case noRequirements
    case unverified
    case supported
    case unsupported(missing: [String])

    /// Evaluates requirements only when the caller has supplied explicit
    /// provider evidence. Passing `nil` keeps the result unverified, even if
    /// the host hardware appears to imply the capability.
    public static func evaluate(
        required: [String]?,
        observed: Set<String>?
    ) -> Self {
        guard let required else { return .unverified }
        let normalized = required.reduce(into: [String]()) { values, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !values.contains(trimmed) else { return }
            values.append(trimmed)
        }
        guard !normalized.isEmpty else { return .noRequirements }
        guard let observed else { return .unverified }
        let missing = normalized.filter { !observed.contains($0) }
        return missing.isEmpty ? .supported : .unsupported(missing: missing)
    }
}

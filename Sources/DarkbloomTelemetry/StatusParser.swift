import Foundation

public enum StatusParser {
    public static func parse(_ text: String) -> StatusSnapshot {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var snapshot = StatusSnapshot()

        if let first = lines.first, first.hasPrefix("darkbloom ") {
            snapshot.version = String(first.dropFirst("darkbloom ".count))
        }

        snapshot.providerName = value(after: "Provider:", in: lines)
        snapshot.configPath = value(after: "Config:", in: lines)
        snapshot.coordinator = value(after: "Coordinator:", in: lines)
        snapshot.backendPort = value(after: "Backend port:", in: lines).flatMap(Int.init)
        snapshot.configuredModel = value(after: "Configured model:", in: lines)
        snapshot.idleTimeout = value(after: "Idle timeout:", in: lines)
        snapshot.betaFeatures = value(after: "Beta features:", in: lines)
        snapshot.autoRestart = value(after: "Auto-restart:", in: lines)
        snapshot.hardware = value(after: "Hardware:", in: lines)
        snapshot.inferenceMemory = value(after: "Inference memory:", in: lines)
        snapshot.bootChecks = value(after: "Local boot checks:", in: lines)
        snapshot.schedule = value(after: "Schedule:", in: lines)
        snapshot.enabledModelFilter = value(after: "Enabled model filter:", in: lines)
        snapshot.localModelCount = value(after: "Local MLX models:", in: lines).flatMap(Int.init)
        snapshot.daemon = value(after: "Daemon:", in: lines)
        snapshot.trust = value(after: "Trust:", in: lines)
        snapshot.trustReason = value(after: "→ coordinator reason:", in: lines)
        snapshot.warmModels = commaSeparated(value(after: "Warm models:", in: lines))
        snapshot.mostRecentlyUsed = value(after: "Most recently used:", in: lines)
        snapshot.stateAge = value(after: "Slot posture:", in: lines)
            .map { $0.replacingOccurrences(of: "state written ", with: "") }
        snapshot.slotPosture = lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.contains(": kv=") ? trimmed : nil
        }

        if let counters = lines.first(where: { $0.hasPrefix("Requests served:") }) {
            let halves = counters.split(separator: "|", maxSplits: 1).map(String.init)
            snapshot.requestCount = halves.first
                .flatMap { value(after: "Requests served:", in: [$0]) }
                .flatMap(Int64.init)
            snapshot.tokenCount = halves.dropFirst().first
                .flatMap { value(after: "tokens:", in: [$0]) }
                .flatMap(Int64.init)
        }

        return snapshot
    }

    private static func value(after prefix: String, in lines: [String]) -> String? {
        lines.lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func commaSeparated(_ value: String?) -> [String] {
        guard let value, value.lowercased() != "none" else { return [] }
        return value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }
}

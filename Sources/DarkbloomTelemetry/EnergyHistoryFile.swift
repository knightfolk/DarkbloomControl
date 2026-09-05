import Foundation

/// Atomic, bounded local persistence. Acquisition continuity is never persisted.
public enum EnergyHistoryFile {
    public static let maximumBytes = 24 * 1024 * 1024

    private struct Envelope: Codable {
        let schema: Int
        let intervals: [EnergyInterval]
    }

    public static func read(from url: URL) throws -> EnergyHistory {
        guard FileManager.default.fileExists(atPath: url.path) else { return EnergyHistory() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw EnergyHistoryError.tooLarge }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schema == 1 else { throw EnergyHistoryError.unsupportedSchema }
        return try EnergyHistory(restoring: envelope.intervals)
    }

    public static func write(_ history: EnergyHistory, to url: URL) throws {
        let data = try JSONEncoder().encode(Envelope(schema: 1, intervals: history.intervals))
        guard data.count <= maximumBytes else { throw EnergyHistoryError.tooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

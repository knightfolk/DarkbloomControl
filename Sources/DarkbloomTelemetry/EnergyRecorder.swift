import Foundation

public struct EnergyRecordingSnapshot: Sendable {
    public let reading: EnergyReading?
    public let intervals: [EnergyInterval]
    public let issue: String?
}

/// One owner serializes acquisition and atomic persistence. No privileged tools.
public actor EnergyRecorder {
    private let file: URL
    private let readPower: @Sendable (Date) -> EnergyReading?
    private var history: EnergyHistory?

    public init(file: URL, readPower: @escaping @Sendable (Date) -> EnergyReading? = {
        MacAdapterPower.read(now: $0)
    }) {
        self.file = file
        self.readPower = readPower
    }

    public func sample(enabled: Bool, rate: Double?, now: Date) -> EnergyRecordingSnapshot {
        guard enabled else {
            history?.breakContinuity()
            return .init(reading: nil, intervals: [], issue: nil)
        }
        do {
            if history == nil { history = try EnergyHistoryFile.read(from: file) }
        } catch {
            return .init(reading: nil, intervals: [], issue: "Energy history could not be read; existing file preserved.")
        }
        guard let rate, rate.isFinite, rate >= 0 else {
            history?.breakContinuity()
            return .init(reading: nil, intervals: [], issue: "Enter a valid electricity price in Settings.")
        }
        guard let reading = readPower(now) else {
            history?.breakContinuity()
            return .init(reading: nil, intervals: history?.intervals ?? [], issue: "Adapter power unavailable; measurement gap.")
        }
        history?.append(reading, usdPerKWh: rate)
        do {
            if let history { try EnergyHistoryFile.write(history, to: file) }
            return .init(reading: reading, intervals: history?.intervals ?? [], issue: nil)
        } catch {
            history?.breakContinuity()
            return .init(reading: reading, intervals: [], issue: "Energy history could not be saved.")
        }
    }
}

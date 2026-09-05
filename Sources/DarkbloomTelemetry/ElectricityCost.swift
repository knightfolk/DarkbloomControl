import Foundation

/// Currency matches account earnings (USD). Missing rates are not free power.
public enum ElectricityCost {
    public static func rate(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// Integrate only adjacent valid samples; gaps over 30 seconds are unknown.
    public static func kilowattHours(startWatts: Double, endWatts: Double, seconds: Double) -> Double? {
        guard startWatts.isFinite, endWatts.isFinite, seconds.isFinite,
              startWatts >= 0, endWatts >= 0, seconds > 0, seconds <= 30 else { return nil }
        let value = (startWatts / 2 + endWatts / 2) * seconds / 3_600_000
        return value.isFinite ? value : nil
    }
}

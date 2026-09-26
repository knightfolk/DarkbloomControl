import Foundation

/// Presentation model for the GPU ring drawn around the menu-bar model logo.
/// Utilization is whole-Mac: it is never attributed to the serving model or
/// to Darkbloom itself, and the accessibility text says so explicitly.
public struct MenuBarGPURing: Equatable, Sendable {
    public enum Tint: Equatable, Sendable {
        case green
        case yellow
        case red
        case neutral
    }

    /// Color boundaries for the ring tint. These are presentation choices
    /// for this app's UI, not Apple hardware safety limits.
    public struct Thresholds: Equatable, Sendable {
        public static let standard = Self(yellowAtCelsius: 70, redAtCelsius: 85)

        public let yellowAtCelsius: Double
        public let redAtCelsius: Double

        public init(yellowAtCelsius: Double, redAtCelsius: Double) {
            self.yellowAtCelsius = yellowAtCelsius
            self.redAtCelsius = redAtCelsius
        }
    }

    /// Matches the dashboard's resource panel: a utilization sample older
    /// than this is missing data, not a real 0% or 100% reading.
    public static let maximumUtilizationAge: TimeInterval = 10

    public let utilization: Double
    public let temperatureCelsius: Double?
    public let tint: Tint

    public init(utilization: Double, temperatureCelsius: Double?, tint: Tint) {
        self.utilization = utilization
        self.temperatureCelsius = temperatureCelsius
        self.tint = tint
    }

    /// Fraction of the ring to fill: 0 is an empty track, 1 a complete ring.
    public var progress: Double { utilization / 100 }

    public var accessibilityDetail: String {
        let percent = utilization.formatted(.number.precision(.fractionLength(0)))
        var detail = "Whole-Mac GPU use \(percent) percent"
        if let temperatureCelsius {
            let temperature = temperatureCelsius.formatted(.number.precision(.fractionLength(0)))
            detail += ", GPU \(temperature) degrees Celsius"
        }
        return detail + "."
    }

    /// Returns nil when there is no fresh valid utilization sample. Callers
    /// render no ring at all rather than fabricate an empty or full arc.
    public static func make(
        utilization: Double?,
        sampledAt: Date?,
        fanStatus: SourceAvailability<ProviderFanStatus>?,
        now: Date,
        thresholds: Thresholds = .standard
    ) -> Self? {
        guard let utilization,
              utilization.isFinite,
              (0...100).contains(utilization),
              let sampledAt else { return nil }
        let age = now.timeIntervalSince(sampledAt)
        guard age.isFinite, (0...maximumUtilizationAge).contains(age) else { return nil }

        let temperature = freshTemperatureCelsius(from: fanStatus, now: now)
        return Self(
            utilization: utilization,
            temperatureCelsius: temperature,
            tint: tint(for: temperature, thresholds: thresholds)
        )
    }

    /// The freshest valid temperature available: a fresh helper-journal
    /// temperature wins, otherwise the hottest sensor from a still-fresh
    /// same-command diagnostic (the helper itself colors by the hottest GPU
    /// sensor, so the diagnostic fallback mirrors it). Stale or missing
    /// sources yield nil — an old reading is never extended just because the
    /// UI re-rendered.
    static func freshTemperatureCelsius(
        from fanStatus: SourceAvailability<ProviderFanStatus>?,
        now: Date
    ) -> Double? {
        guard case .available(let status, let capturedAt) = fanStatus else { return nil }
        let age = now.timeIntervalSince(capturedAt)
        guard age.isFinite, (0...ProviderExtrasSnapshot.maximumSourceAge).contains(age) else {
            return nil
        }

        let current = status.helperIsFresh(at: now) ? status : status.withoutHelper()
        if let helperTemperature = current.helper?.gpuTemperatureCelsius,
           validTemperature(helperTemperature) {
            return helperTemperature
        }
        let sensors = current.diagnostic.gpuTemperatures.map(\.celsius).filter(validTemperature)
        return sensors.max()
    }

    /// Matches the official CLI's sensor plausibility range
    /// (`FanHardware.plausibleTemperatureRange`, 10...125 C).
    static func validTemperature(_ value: Double) -> Bool {
        value.isFinite && (10...125).contains(value)
    }

    static func tint(for temperature: Double?, thresholds: Thresholds) -> Tint {
        guard let temperature, validTemperature(temperature) else { return .neutral }
        if temperature >= thresholds.redAtCelsius { return .red }
        if temperature >= thresholds.yellowAtCelsius { return .yellow }
        return .green
    }
}

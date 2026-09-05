import Foundation

public enum SystemThermalState: String, CaseIterable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    public var displayName: String { rawValue.capitalized }

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

public enum RoutingHealthColor: Equatable, Sendable {
    case green
    case yellow
    case orange
    case red
}

public struct RoutingHealth: Equatable, Sendable {
    public let color: RoutingHealthColor
    public let isRoutable: Bool
    public let reason: String

    static func derive(
        menuStatus: MenuPresentationStatus,
        thermal: SystemThermalState
    ) -> Self {
        guard menuStatus == .online else {
            let reason = switch menuStatus {
            case .online: ""
            case .stale: "Provider routing state is stale"
            case .offline: "Provider is offline"
            case .unavailable: "Provider routing state is unavailable"
            }
            return Self(color: .red, isRoutable: false, reason: reason)
        }

        switch thermal {
        case .nominal:
            return Self(color: .green, isRoutable: true, reason: "Thermal state nominal")
        case .fair:
            return Self(color: .yellow, isRoutable: true, reason: "Thermal state fair — routing degraded")
        case .serious:
            return Self(color: .orange, isRoutable: true, reason: "Thermal state serious — routing heavily degraded")
        case .critical:
            return Self(color: .red, isRoutable: false, reason: "Critical thermal pressure")
        }
    }
}

public enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case throughput
    case earnings
    case model
    case statusOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .throughput: "Throughput"
        case .earnings: "Earnings"
        case .model: "Model"
        case .statusOnly: "Status only"
        }
    }
}

public enum EarningsPresentationValue: Equatable, Sendable {
    case day(microUSD: Int64, complete: Bool)
    case available(microUSD: Int64)
    case observed(microUSD: Int64, observedSeconds: TimeInterval)
    case stale(microUSD: Int64, reason: String)
    case unavailable(reason: String)

    public static func calendarDay(_ value: ObservedEarningsWindow?, now: Date, calendar: Calendar) -> Self {
        guard let value, let start = value.calendarDayStart, let captured = value.capturedAt,
              start == calendar.startOfDay(for: now), captured >= start,
              now.timeIntervalSince(captured).isFinite,
              (0...600).contains(now.timeIntervalSince(captured)),
              value.observedSeconds.isFinite, value.observedSeconds > 0,
              value.microUSD >= 0 else {
            return .unavailable(reason: "Today's earnings unavailable or expired")
        }
        return .day(microUSD: value.microUSD, complete: value.coversDayToDate)
    }
}

public struct MenuBarPresentation: Equatable, Sendable {
    public let health: RoutingHealth
    public let thermal: SystemThermalState
    public let metricText: String?
    public let metricUnavailableReason: String?
    public let accessibilityLabel: String

    public static func make(
        snapshot: TelemetrySnapshot,
        thermal: SystemThermalState,
        earnings: EarningsPresentationValue,
        mode: MenuBarDisplayMode,
        activeModelAverage: Double? = nil
    ) -> Self {
        let health = RoutingHealth.derive(menuStatus: snapshot.menuStatus, thermal: thermal)
        let metric = metric(snapshot: snapshot, earnings: earnings, mode: mode, activeModelAverage: activeModelAverage)
        let routingText = health.isRoutable ? "Darkbloom routable" : "Darkbloom not routable"
        let statusText = "\(routingText), thermal \(thermal.rawValue)."
        let accessibilityLabel = metric.accessibility.map { "\(statusText) \($0)" } ?? statusText

        return Self(
            health: health,
            thermal: thermal,
            metricText: metric.text,
            metricUnavailableReason: metric.unavailableReason,
            accessibilityLabel: accessibilityLabel
        )
    }

    private struct Metric {
        let text: String?
        let accessibility: String?
        let unavailableReason: String?
    }

    private static func metric(
        snapshot: TelemetrySnapshot,
        earnings: EarningsPresentationValue,
        mode: MenuBarDisplayMode,
        activeModelAverage: Double?
    ) -> Metric {
        switch mode {
        case .automatic, .throughput:
            if let throughput = availableThroughput(snapshot.tokenRate) {
                return throughput
            }
            if snapshot.menuStatus == .online, snapshot.state.value?.inferenceActive == true {
                if let average = activeModelAverage, average.isFinite, average > 0 {
                    return Metric(text: "\(decimal(average, fractionDigits: 0))t/s avg",
                                  accessibility: "Working. Today's model average \(average) tokens per second; live rate unavailable.",
                                  unavailableReason: "Working — showing today's model average, not realtime throughput")
                }
                return Metric(text: "Working", accessibility: "Working; live token rate unavailable.",
                              unavailableReason: "The provider has not exposed a live token rate")
            }
            if let earnings = availableEarnings(earnings) {
                return earnings
            }
            return unavailableMetric(earningsUnavailableReason(earnings))
        case .earnings:
            return availableEarnings(earnings)
                ?? unavailableMetric(earningsUnavailableReason(earnings))
        case .model:
            guard let model = snapshot.state.value?.currentModel, !model.isEmpty else {
                return unavailableMetric("Current model unavailable")
            }
            return Metric(text: model, accessibility: "Current model \(model).", unavailableReason: nil)
        case .statusOnly:
            return Metric(text: nil, accessibility: nil, unavailableReason: nil)
        }
    }

    private static func availableThroughput(_ rate: TokenRate) -> Metric? {
        guard case .available(let tokensPerSecond, _) = rate,
              tokensPerSecond.isFinite else {
            return nil
        }
        let compact = decimal(tokensPerSecond, fractionDigits: 1)
        return Metric(
            text: "\(compact) tok/s",
            accessibility: "\(compact) tokens per second.",
            unavailableReason: nil
        )
    }

    private static func availableEarnings(_ earnings: EarningsPresentationValue) -> Metric? {
        let microUSD: Int64
        let windowText: String
        let accessibility: String
        switch earnings {
        case .day(let value, let complete):
            microUSD = value
            windowText = complete ? "d" : "d*"
            accessibility = complete ? "earned today" : "observed today; partial-day coverage"
        case .available(let value):
            microUSD = value
            windowText = "24h"
            accessibility = "earned in the last 24 hours"
        case .observed(let value, let observedSeconds):
            guard observedSeconds.isFinite, observedSeconds > 0 else { return nil }
            microUSD = value
            if observedSeconds < 3_600 {
                windowText = "<1h"
                accessibility = "observed over less than one hour"
            } else {
                let hours = min(24, max(1, Int((observedSeconds / 3_600).rounded())))
                windowText = "\(hours)h"
                accessibility = "observed over \(hours) hours"
            }
        case .stale, .unavailable:
            return nil
        }
        let dollars = Double(microUSD) / 1_000_000
        let compact = decimal(dollars, fractionDigits: 2)
        return Metric(
            text: "$\(compact)/\(windowText)",
            accessibility: "\(compact) dollars \(accessibility).",
            unavailableReason: nil
        )
    }

    private static func earningsUnavailableReason(
        _ earnings: EarningsPresentationValue
    ) -> String {
        switch earnings {
        case .available, .observed, .day:
            "Earnings unavailable"
        case .stale(_, let reason):
            "Rolling earnings stale — \(reason)"
        case .unavailable(let reason):
            reason
        }
    }

    private static func unavailableMetric(_ reason: String) -> Metric {
        Metric(text: nil, accessibility: nil, unavailableReason: reason)
    }

    private static func decimal(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

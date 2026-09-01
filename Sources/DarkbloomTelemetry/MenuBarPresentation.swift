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
    case available(microUSD: Int64)
    case stale(microUSD: Int64, reason: String)
    case unavailable(reason: String)
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
        mode: MenuBarDisplayMode
    ) -> Self {
        let health = RoutingHealth.derive(menuStatus: snapshot.menuStatus, thermal: thermal)
        let metric = metric(snapshot: snapshot, earnings: earnings, mode: mode)
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
        mode: MenuBarDisplayMode
    ) -> Metric {
        let selectedMode: MenuBarDisplayMode
        if mode == .automatic {
            guard let state = snapshot.state.value else {
                return Metric(text: "—", accessibility: "Selected metric unavailable.", unavailableReason: "Daemon state unavailable")
            }
            selectedMode = state.inferenceActive ? .throughput : .earnings
        } else {
            selectedMode = mode
        }

        switch selectedMode {
        case .automatic:
            preconditionFailure("Automatic mode must be resolved before formatting")
        case .throughput:
            switch snapshot.tokenRate {
            case .available(let tokensPerSecond, _):
                guard tokensPerSecond.isFinite else {
                    return unavailableMetric("Token rate is not finite")
                }
                let compact = decimal(tokensPerSecond, fractionDigits: 1)
                return Metric(
                    text: "\(compact) tok/s",
                    accessibility: "\(compact) tokens per second.",
                    unavailableReason: nil
                )
            case .unavailable(let reason):
                return unavailableMetric(reason)
            }
        case .earnings:
            switch earnings {
            case .available(let microUSD):
                let dollars = Double(microUSD) / 1_000_000
                let compact = decimal(dollars, fractionDigits: 2)
                return Metric(
                    text: "$\(compact)/24h",
                    accessibility: "\(compact) dollars earned in the last 24 hours.",
                    unavailableReason: nil
                )
            case .stale(_, let reason):
                return unavailableMetric("Rolling earnings stale — \(reason)")
            case .unavailable(let reason):
                return unavailableMetric(reason)
            }
        case .model:
            guard let model = snapshot.state.value?.currentModel, !model.isEmpty else {
                return unavailableMetric("Current model unavailable")
            }
            return Metric(text: model, accessibility: "Current model \(model).", unavailableReason: nil)
        case .statusOnly:
            return Metric(text: nil, accessibility: nil, unavailableReason: nil)
        }
    }

    private static func unavailableMetric(_ reason: String) -> Metric {
        Metric(text: "—", accessibility: "Selected metric unavailable.", unavailableReason: reason)
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

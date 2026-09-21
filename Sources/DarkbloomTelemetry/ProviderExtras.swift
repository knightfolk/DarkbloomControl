import Foundation

/// The bounded idle-memory policy reported by `darkbloom idle status --json`.
/// `0` means that models are kept resident while the provider is idle.
public struct ProviderIdlePolicy: Equatable, Sendable {
    public static let maximumMinutes = 10_080

    public let idleTimeoutMinutes: Int
    public let policy: String
    public let summary: String
    public let pinned: Bool

    public init(
        idleTimeoutMinutes: Int,
        policy: String,
        summary: String,
        pinned: Bool
    ) {
        self.idleTimeoutMinutes = idleTimeoutMinutes
        self.policy = policy
        self.summary = summary
        self.pinned = pinned
    }

    public var requiresRestart: Bool { true }

    public static func isValid(minutes: Int) -> Bool {
        (0...maximumMinutes).contains(minutes)
    }
}

public enum ProviderBetaFeatureState: String, Equatable, Sendable {
    case auto
    case on
    case off
}

/// A beta feature keeps the CLI's tri-state posture. In particular, automatic
/// MTP does not have an honest global Boolean projection, so `enabled` is nil
/// for `auto`.
public struct ProviderBetaFeature: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let state: ProviderBetaFeatureState
    public let enabled: Bool?
    public let requiresRestart: Bool
    public let summary: String

    public init(
        id: String,
        title: String,
        state: ProviderBetaFeatureState,
        enabled: Bool?,
        requiresRestart: Bool,
        summary: String
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.enabled = enabled
        self.requiresRestart = requiresRestart
        self.summary = summary
    }

    public var stateLabel: String {
        switch state {
        case .auto: "Automatic"
        case .on: "Enabled"
        case .off: "Disabled"
        }
    }
}

public struct ProviderFanReading: Equatable, Sendable, Identifiable {
    public let index: Int
    public let actualRPM: Double?
    public let targetRPM: Double?
    public let minimumRPM: Double?
    public let maximumRPM: Double?
    public let mode: String?

    public var id: Int { index }

    public init(
        index: Int,
        actualRPM: Double?,
        targetRPM: Double?,
        minimumRPM: Double?,
        maximumRPM: Double?,
        mode: String?
    ) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.mode = mode
    }
}

public struct ProviderFanTemperature: Equatable, Sendable, Identifiable {
    public let key: String
    public let celsius: Double

    public var id: String { key }

    public init(key: String, celsius: Double) {
        self.key = key
        self.celsius = celsius
    }
}

public struct ProviderFanHelperStatus: Equatable, Sendable {
    public let enabled: Bool
    public let providerActive: Bool
    public let mode: String
    public let chip: String
    public let gpuTemperatureCelsius: Double?
    public let triggerTemperatureCelsius: Double
    public let releaseTemperatureCelsius: Double
    public let speedPercent: Double
    public let fans: [ProviderFanReading]
    public let updatedAt: Date

    public init(
        enabled: Bool,
        providerActive: Bool,
        mode: String,
        chip: String,
        gpuTemperatureCelsius: Double?,
        triggerTemperatureCelsius: Double,
        releaseTemperatureCelsius: Double,
        speedPercent: Double,
        fans: [ProviderFanReading],
        updatedAt: Date
    ) {
        self.enabled = enabled
        self.providerActive = providerActive
        self.mode = mode
        self.chip = chip
        self.gpuTemperatureCelsius = gpuTemperatureCelsius
        self.triggerTemperatureCelsius = triggerTemperatureCelsius
        self.releaseTemperatureCelsius = releaseTemperatureCelsius
        self.speedPercent = speedPercent
        self.fans = fans
        self.updatedAt = updatedAt
    }
}

public struct ProviderFanDiagnostic: Equatable, Sendable {
    public let chip: String
    public let supported: Bool
    public let gpuTemperatures: [ProviderFanTemperature]
    public let fans: [ProviderFanReading]

    public init(
        chip: String,
        supported: Bool,
        gpuTemperatures: [ProviderFanTemperature],
        fans: [ProviderFanReading]
    ) {
        self.chip = chip
        self.supported = supported
        self.gpuTemperatures = gpuTemperatures
        self.fans = fans
    }
}

/// Read-only fan and GPU sensor posture. The CLI's free-form error strings are
/// intentionally represented only by the source availability around this value;
/// they can contain paths or other local diagnostic material.
public struct ProviderFanStatus: Equatable, Sendable {
    public static let maximumHelperAge: TimeInterval = 15

    public let capability: String
    public let installed: Bool
    public let loaded: Bool
    public let helper: ProviderFanHelperStatus?
    public let diagnostic: ProviderFanDiagnostic
    public let helperErrorPresent: Bool
    public let diagnosticErrorPresent: Bool

    public init(
        capability: String,
        installed: Bool,
        loaded: Bool,
        helper: ProviderFanHelperStatus?,
        diagnostic: ProviderFanDiagnostic,
        helperErrorPresent: Bool,
        diagnosticErrorPresent: Bool
    ) {
        self.capability = capability
        self.installed = installed
        self.loaded = loaded
        self.helper = helper
        self.diagnostic = diagnostic
        self.helperErrorPresent = helperErrorPresent
        self.diagnosticErrorPresent = diagnosticErrorPresent
    }

    public func helperIsFresh(at now: Date) -> Bool {
        guard let helper else { return true }
        let age = now.timeIntervalSince(helper.updatedAt)
        return age.isFinite && age >= 0 && age <= Self.maximumHelperAge
    }

    /// Keep a same-command diagnostic reading when the helper's own journal is
    /// stale. The helper metadata is intentionally dropped so the UI cannot
    /// accidentally present old helper temperature/RPM values as current.
    public func withoutHelper() -> Self {
        Self(
            capability: capability,
            installed: installed,
            loaded: loaded,
            helper: nil,
            diagnostic: diagnostic,
            helperErrorPresent: helperErrorPresent,
            diagnosticErrorPresent: diagnosticErrorPresent
        )
    }

    public var displayedTemperatureCelsius: Double? {
        helper?.gpuTemperatureCelsius ?? diagnostic.gpuTemperatures.first?.celsius
    }

    public var displayedFans: [ProviderFanReading] {
        guard let helper, !helper.fans.isEmpty else { return diagnostic.fans }
        return helper.fans
    }
}

public struct ProviderAutoUpdateStatus: Equatable, Sendable {
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

/// A read of the optional CLI extras. Each command has its own availability so
/// one unsupported or malformed source never hides the others.
public struct ProviderExtrasSnapshot: Equatable, Sendable {
    public static let maximumSourceAge: TimeInterval = 45
    public let capturedAt: Date
    public let idlePolicy: SourceAvailability<ProviderIdlePolicy>
    public let betaFeatures: SourceAvailability<[ProviderBetaFeature]>
    public let fanStatus: SourceAvailability<ProviderFanStatus>
    public let autoUpdateStatus: SourceAvailability<ProviderAutoUpdateStatus>?

    public init(
        capturedAt: Date,
        idlePolicy: SourceAvailability<ProviderIdlePolicy>,
        betaFeatures: SourceAvailability<[ProviderBetaFeature]>,
        fanStatus: SourceAvailability<ProviderFanStatus>,
        autoUpdateStatus: SourceAvailability<ProviderAutoUpdateStatus>? = nil
    ) {
        self.capturedAt = capturedAt
        self.idlePolicy = idlePolicy
        self.betaFeatures = betaFeatures
        self.fanStatus = fanStatus
        self.autoUpdateStatus = autoUpdateStatus
    }

    public var idle: SourceAvailability<ProviderIdlePolicy> { idlePolicy }
    public var beta: SourceAvailability<[ProviderBetaFeature]> { betaFeatures }
    public var fan: SourceAvailability<ProviderFanStatus> { fanStatus }
}

public enum ProviderExtrasParseError: Error, Equatable, Sendable {
    case invalidPayload
    case invalidValue
    case unsupportedValue
}

public enum ProviderExtrasMutationError: Error, Equatable, Sendable {
    case invalidIdleMinutes
    case unsupportedBetaFeature
    case executableUnavailable
    case commandFailed
    case mutationInProgress
}

public extension ProviderExtrasMutationError {
    var userMessage: String {
        switch self {
        case .invalidIdleMinutes:
            "Choose an idle window from 0 to 10,080 minutes."
        case .unsupportedBetaFeature:
            "That beta feature is not available for changes in this app."
        case .executableUnavailable:
            "The Darkbloom command is unavailable."
        case .commandFailed:
            "Darkbloom could not save that setting."
        case .mutationInProgress:
            "Another Darkbloom setting change is already in progress."
        }
    }
}

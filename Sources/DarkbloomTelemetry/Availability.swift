import Foundation

public enum SourceAvailability<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(value: Value, capturedAt: Date)
    case stale(value: Value, capturedAt: Date, reason: String)
    case unavailable(reason: String)

    public var value: Value? {
        switch self {
        case .available(let value, _), .stale(let value, _, _):
            value
        case .unavailable:
            nil
        }
    }
}

public enum DerivedDuration: Equatable, Sendable {
    case available(seconds: TimeInterval, label: String)
    case unavailable(reason: String)
}

public enum TelemetryContractError: Error, Equatable, Sendable {
    case unsupportedSchema(source: String, found: Int, supported: Int)
}

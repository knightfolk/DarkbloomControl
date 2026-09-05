import Foundation

public enum NetworkDemandBand: String, Equatable, Sendable {
    case low
    case moderate
    case high
    case urgent
}

public struct NetworkModelCapacity: Equatable, Identifiable, Sendable, Decodable {
    public let id: String
    public let ready: Bool
    public let canAccept: Bool
    public let routableProviders: Int
    public let warmProviders: Int
    public let runningProviders: Int
    public let coldProviders: Int
    public let activeRequests: Int
    public let queuedRequests: Int
    public let queueLimit: Int
    public let aggregateTokensPerSecond: Double
    public let estimatedTimeToFirstTokenMS: Int
    public let tokenBudgetRemaining: Int64
    public let tokenBudgetTotal: Int64

    enum CodingKeys: String, CodingKey {
        case id, ready
        case canAccept = "can_accept"
        case routableProviders = "routable_providers"
        case warmProviders = "warm_providers"
        case runningProviders = "running_providers"
        case coldProviders = "cold_providers"
        case activeRequests = "active_requests"
        case queuedRequests = "queued_requests"
        case queueLimit = "queue_limit"
        case aggregateTokensPerSecond = "aggregate_tps"
        case estimatedTimeToFirstTokenMS = "estimated_ttft_ms"
        case tokenBudgetRemaining = "token_budget_remaining"
        case tokenBudgetTotal = "token_budget_total"
    }

    public var demandPerWarmProvider: Double? {
        guard warmProviders > 0 else { return nil }
        return (Double(activeRequests) + Double(queuedRequests)) / Double(warmProviders)
    }

    public var demandBand: NetworkDemandBand {
        Self.demandBand(
            activeRequests: activeRequests,
            queuedRequests: queuedRequests,
            warmProviders: warmProviders
        )
    }

    public static func demandBand(
        activeRequests: Int,
        queuedRequests: Int,
        warmProviders: Int
    ) -> NetworkDemandBand {
        if queuedRequests > 0 { return .urgent }
        if warmProviders == 0 { return activeRequests > 0 ? .urgent : .low }
        let pressure = Double(activeRequests) / Double(warmProviders)
        if pressure >= 1 { return .urgent }
        if pressure >= 0.5 { return .high }
        if pressure >= 0.1 { return .moderate }
        return .low
    }

    fileprivate var isValid: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && id.utf8.count <= 512
            && routableProviders >= 0
            && warmProviders >= 0
            && runningProviders >= 0
            && coldProviders >= 0
            && activeRequests >= 0
            && queuedRequests >= 0
            && queueLimit >= 0
            && aggregateTokensPerSecond.isFinite
            && aggregateTokensPerSecond >= 0
            && estimatedTimeToFirstTokenMS >= 0
            && tokenBudgetRemaining >= 0
            && tokenBudgetTotal >= 0
            && tokenBudgetRemaining <= tokenBudgetTotal
    }
}

public struct NetworkCapacitySnapshot: Equatable, Sendable {
    /// Network demand is only suitable for automatic model decisions while it
    /// is recent enough to describe the current routing pressure.
    public static let maximumAge: TimeInterval = 120
    public static let maximumFutureSkew: TimeInterval = 5

    public let models: [NetworkModelCapacity]
    public let capturedAt: Date

    public init(models: [NetworkModelCapacity], capturedAt: Date) {
        self.models = models
        self.capturedAt = capturedAt
    }

    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age.isFinite
            && age >= -Self.maximumFutureSkew
            && age <= Self.maximumAge
    }
}

public enum NetworkCapacityError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
}

extension NetworkCapacityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The Darkbloom model-capacity endpoint is invalid"
        case .invalidResponse:
            "Darkbloom model capacity returned an invalid response"
        case .responseTooLarge:
            "Darkbloom model capacity exceeded the allowed size"
        case .httpStatus(let status):
            "Darkbloom model capacity returned HTTP \(status)"
        }
    }
}

public enum NetworkCapacityParser {
    private struct Envelope: Decodable {
        let models: [NetworkModelCapacity]
    }

    public static func parse(_ data: Data, capturedAt: Date) throws -> NetworkCapacitySnapshot {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw NetworkCapacityError.invalidResponse
        }
        guard envelope.models.count <= 128,
              envelope.models.allSatisfy(\.isValid),
              Set(envelope.models.map(\.id)).count == envelope.models.count
        else {
            throw NetworkCapacityError.invalidResponse
        }
        return NetworkCapacitySnapshot(models: envelope.models, capturedAt: capturedAt)
    }
}

public struct NetworkCapacityRequest: Sendable {
    public let urlRequest: URLRequest

    public static func make() -> Self {
        var request = URLRequest(
            url: URL(string: "https://api.darkbloom.dev/v1/models/capacity")!,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return Self(urlRequest: request)
    }
}

public protocol NetworkCapacityFetching: Sendable {
    func fetch(at capturedAt: Date) async throws -> NetworkCapacitySnapshot
}

enum BoundedNetworkBody {
    static func collect<Bytes: AsyncSequence>(_ bytes: Bytes, maximumBytes: Int) async throws -> Data where Bytes.Element == UInt8 {
        try Task.checkCancellation()
        guard maximumBytes >= 0 else { throw NetworkCapacityError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 4096))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw NetworkCapacityError.responseTooLarge }
            data.append(byte)
        }
        return data
    }
}

public struct PublicNetworkCapacityClient: NetworkCapacityFetching, Sendable {
    public static let maximumResponseBytes = 256 * 1_024
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? PublicHTTPSession.shared
    }

    public func fetch(at capturedAt: Date) async throws -> NetworkCapacitySnapshot {
        let request = NetworkCapacityRequest.make()
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request.urlRequest)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw NetworkCapacityError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NetworkCapacityError.httpStatus(http.statusCode)
        }
        guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
            throw NetworkCapacityError.responseTooLarge
        }
        let data = try await BoundedNetworkBody.collect(bytes, maximumBytes: Self.maximumResponseBytes)
        return try NetworkCapacityParser.parse(data, capturedAt: capturedAt)
    }
}

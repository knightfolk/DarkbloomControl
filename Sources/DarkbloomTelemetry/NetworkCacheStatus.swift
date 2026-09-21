import Foundation

/// Deliberately retains only aggregate rollout health, never per-request or
/// per-provider data. This is not evidence of the local Mac's cache performance.
public struct NetworkCacheSnapshot: Equatable, Sendable {
    public enum RoutingMode: String, Sendable { case on, off, shadow, unknown }
    public let routingMode: RoutingMode
    public let plannerEnabled: Bool?
    public let plannerRunning: Bool?
    public let plannerReady: Bool?
    public let capturedAt: Date

    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age.isFinite && (0...120).contains(age)
    }

    public static func parse(_ data: Data, capturedAt: Date) throws -> Self {
        guard data.count <= 256 * 1_024 else { throw NetworkCapacityError.responseTooLarge }
        struct Envelope: Decodable {
            struct Sidecar: Decodable { let enabled: Bool?; let running: Bool?; let ready: Bool? }
            let routing_mode: String
            let sidecar: Sidecar?
        }
        guard capturedAt.timeIntervalSince1970.isFinite,
              let raw = try? JSONDecoder().decode(Envelope.self, from: data),
              raw.routing_mode.utf8.count <= 64 else { throw NetworkCapacityError.invalidResponse }
        return Self(routingMode: RoutingMode(rawValue: raw.routing_mode) ?? .unknown,
                    plannerEnabled: raw.sidecar?.enabled, plannerRunning: raw.sidecar?.running,
                    plannerReady: raw.sidecar?.ready, capturedAt: capturedAt)
    }
}

public protocol NetworkCacheFetching: Sendable {
    func fetch(at capturedAt: Date) async throws -> NetworkCacheSnapshot
}

public struct NetworkCacheClient: NetworkCacheFetching, Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) { self.session = session ?? PublicHTTPSession.shared }

    public func fetch(at capturedAt: Date) async throws -> NetworkCacheSnapshot {
        var request = URLRequest(url: URL(string: "https://api.darkbloom.dev/v1/cache/status")!, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw NetworkCapacityError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw NetworkCapacityError.httpStatus(http.statusCode) }
        guard response.expectedContentLength <= 256 * 1_024 else { throw NetworkCapacityError.responseTooLarge }
        let data = try await BoundedNetworkBody.collect(bytes, maximumBytes: 256 * 1_024)
        return try NetworkCacheSnapshot.parse(data, capturedAt: capturedAt)
    }
}

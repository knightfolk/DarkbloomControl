import Foundation

public struct NetworkSeriesBucket: Decodable, Equatable, Sendable, Identifiable {
    public let timestamp: Date
    public let requests: Int64
    public let promptTokens: Int64
    public let completionTokens: Int64
    public var id: Date { timestamp }
    enum CodingKeys: String, CodingKey {
        case timestamp, requests
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

/// Network-wide aggregates, not local or model-attributed work.
public struct NetworkSeriesSnapshot: Equatable, Sendable {
    public static let maximumResponseBytes = 256 * 1_024
    public let buckets: [NetworkSeriesBucket]
    public let bucketSeconds: Int
    public let startAt: Date
    public let endAt: Date
    public let updatedAt: Date
    public let capturedAt: Date

    public static func parse(_ data: Data, capturedAt: Date) throws -> Self {
        guard data.count <= maximumResponseBytes else { throw NetworkSeriesError.responseTooLarge }
        struct Envelope: Decodable {
            let window: String
            let bucket_seconds: Int
            let start_at: Date
            let end_at: Date
            let updated_at: Date
            let time_series: [NetworkSeriesBucket]
        }
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? fractional.parse(text) { return date }
            if let date = try? whole.parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid network timestamp")
        }
        let result = try decoder.decode(Envelope.self, from: data)
        guard result.window == "24h", result.bucket_seconds > 0, result.bucket_seconds <= 86_400,
              result.end_at.timeIntervalSince(result.start_at) == 86_400,
              result.updated_at >= result.end_at,
              result.time_series.count <= 288, capturedAt.timeIntervalSince1970.isFinite
        else { throw NetworkSeriesError.invalidSeries }
        var previous: Date?
        for bucket in result.time_series {
            let offset = bucket.timestamp.timeIntervalSince(result.start_at)
            guard bucket.requests >= 0, bucket.promptTokens >= 0, bucket.completionTokens >= 0,
                  offset >= 0, bucket.timestamp < result.end_at,
                  bucket.timestamp.addingTimeInterval(Double(result.bucket_seconds)) <= result.end_at,
                  offset.truncatingRemainder(dividingBy: Double(result.bucket_seconds)) == 0,
                  previous.map({ bucket.timestamp > $0 }) ?? true
            else { throw NetworkSeriesError.invalidSeries }
            previous = bucket.timestamp
        }
        return Self(buckets: result.time_series, bucketSeconds: result.bucket_seconds,
                    startAt: result.start_at, endAt: result.end_at, updatedAt: result.updated_at,
                    capturedAt: capturedAt)
    }
}

public enum NetworkSeriesError: Error, Equatable, Sendable {
    case responseTooLarge, invalidSeries, invalidResponse
    case httpStatus(Int)
}

public protocol NetworkSeriesFetching: Sendable {
    func fetch(at capturedAt: Date) async throws -> NetworkSeriesSnapshot
}

public struct NetworkSeriesClient: NetworkSeriesFetching, Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) { self.session = session ?? PublicHTTPSession.shared }

    public func fetch(at capturedAt: Date) async throws -> NetworkSeriesSnapshot {
        var request = URLRequest(url: URL(string: "https://api.darkbloom.dev/v1/network/series?window=24h")!, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw NetworkSeriesError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw NetworkSeriesError.httpStatus(http.statusCode) }
        guard response.expectedContentLength <= Int64(NetworkSeriesSnapshot.maximumResponseBytes) else {
            throw NetworkSeriesError.responseTooLarge
        }
        let data: Data
        do {
            data = try await BoundedNetworkBody.collect(bytes, maximumBytes: NetworkSeriesSnapshot.maximumResponseBytes)
        } catch NetworkCapacityError.responseTooLarge {
            throw NetworkSeriesError.responseTooLarge
        }
        return try NetworkSeriesSnapshot.parse(data, capturedAt: capturedAt)
    }
}

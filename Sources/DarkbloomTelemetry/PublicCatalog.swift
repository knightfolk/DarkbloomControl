import Foundation

public enum PublicCatalogError: Error, Equatable, Sendable {
    case invalidResponse
    case invalidCatalog
    case responseTooLarge
    case httpStatus(Int)
}

/// Public metadata only: never evidence that a model is installed or enabled.
public struct PublicCatalogSnapshot: Equatable, Sendable {
    public static let maximumResponseBytes = 256 * 1_024
    public let models: [CatalogModel]
    public let capturedAt: Date

    public static func parse(_ data: Data, capturedAt: Date) throws -> Self {
        guard data.count <= maximumResponseBytes else { throw PublicCatalogError.responseTooLarge }
        struct Envelope: Decodable { let models: [CatalogModel] }
        let models = try JSONDecoder().decode(Envelope.self, from: data).models
        guard capturedAt.timeIntervalSince1970.isFinite, models.count <= 128,
              Set(models.map(\.id)).count == models.count,
              models.allSatisfy({
                  !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.id.utf8.count <= 512
                      && $0.sizeGB.isFinite && $0.sizeGB >= 0
                      && $0.minimumRAMGB >= 0
              }) else { throw PublicCatalogError.invalidCatalog }
        return Self(models: models, capturedAt: capturedAt)
    }
}

public protocol PublicCatalogFetching: Sendable {
    func fetch(at capturedAt: Date) async throws -> PublicCatalogSnapshot
}

public struct PublicCatalogClient: PublicCatalogFetching, Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) { self.session = session ?? PublicHTTPSession.shared }

    public func fetch(at capturedAt: Date) async throws -> PublicCatalogSnapshot {
        var request = URLRequest(url: URL(string: "https://api.darkbloom.dev/v1/models/catalog")!, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw PublicCatalogError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw PublicCatalogError.httpStatus(http.statusCode) }
        guard response.expectedContentLength <= Int64(PublicCatalogSnapshot.maximumResponseBytes) else {
            throw PublicCatalogError.responseTooLarge
        }
        let data: Data
        do {
            data = try await BoundedNetworkBody.collect(bytes, maximumBytes: PublicCatalogSnapshot.maximumResponseBytes)
        } catch NetworkCapacityError.responseTooLarge {
            throw PublicCatalogError.responseTooLarge
        }
        return try PublicCatalogSnapshot.parse(data, capturedAt: capturedAt)
    }
}

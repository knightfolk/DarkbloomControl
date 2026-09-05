import Foundation

public struct CustomerModelPrice: Decodable, Equatable, Sendable {
    public let model: String
    public let inputMicroUSDPerMillion: Int64
    public let outputMicroUSDPerMillion: Int64

    enum CodingKeys: String, CodingKey {
        case model
        case inputMicroUSDPerMillion = "input_price"
        case outputMicroUSDPerMillion = "output_price"
    }

    public var inputUSDPerMillion: Decimal { Decimal(inputMicroUSDPerMillion) / 1_000_000 }
    public var outputUSDPerMillion: Decimal { Decimal(outputMicroUSDPerMillion) / 1_000_000 }
}

/// Customer-facing rates, never a provider earnings estimate or payout ledger.
public struct PublicPricingSnapshot: Equatable, Sendable {
    public static let maximumResponseBytes = 256 * 1_024
    public let prices: [CustomerModelPrice]
    public let capturedAt: Date

    public func price(for model: String) -> CustomerModelPrice? {
        prices.first { $0.model == model }
    }

    public static func parse(_ data: Data, capturedAt: Date) throws -> Self {
        guard data.count <= maximumResponseBytes else { throw PublicPricingError.responseTooLarge }
        struct Envelope: Decodable { let prices: [CustomerModelPrice] }
        let prices = try JSONDecoder().decode(Envelope.self, from: data).prices
        guard capturedAt.timeIntervalSince1970.isFinite, prices.count <= 128,
              Set(prices.map(\.model)).count == prices.count,
              prices.allSatisfy({
                  !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.model.utf8.count <= 512
                      && $0.inputMicroUSDPerMillion >= 0 && $0.outputMicroUSDPerMillion >= 0
              }) else { throw PublicPricingError.invalidPricing }
        return Self(prices: prices, capturedAt: capturedAt)
    }
}

public enum PublicPricingError: Error, Equatable, Sendable {
    case responseTooLarge, invalidPricing, invalidResponse
    case httpStatus(Int)
}

public protocol PublicPricingFetching: Sendable {
    func fetch(at capturedAt: Date) async throws -> PublicPricingSnapshot
}

public struct PublicPricingClient: PublicPricingFetching, Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) { self.session = session ?? PublicHTTPSession.shared }

    public func fetch(at capturedAt: Date) async throws -> PublicPricingSnapshot {
        var request = URLRequest(url: URL(string: "https://api.darkbloom.dev/v1/pricing")!, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw PublicPricingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw PublicPricingError.httpStatus(http.statusCode) }
        guard response.expectedContentLength <= Int64(PublicPricingSnapshot.maximumResponseBytes) else {
            throw PublicPricingError.responseTooLarge
        }
        let data: Data
        do {
            data = try await BoundedNetworkBody.collect(bytes, maximumBytes: PublicPricingSnapshot.maximumResponseBytes)
        } catch NetworkCapacityError.responseTooLarge {
            throw PublicPricingError.responseTooLarge
        }
        return try PublicPricingSnapshot.parse(data, capturedAt: capturedAt)
    }
}

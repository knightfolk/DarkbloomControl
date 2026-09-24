import Foundation

/// The consumer account balance as authoritatively reported by the Darkbloom
/// network's `GET /v1/payments/balance`. This is the consumer ledger, not the
/// provider account earnings contract, and it is the pre-send gate's only
/// source. A positive value is necessary but never sufficient — the network
/// reserves against each request's upper bound and decides sufficiency per
/// request, so a 402 response remains authoritative even against a positive
/// balance.
public struct ConsumerBalanceSnapshot: Equatable, Sendable {
    public static let maximumResponseBytes = 4 * 1_024
    /// A balance observation older than this is stale and fails the send gate
    /// closed; a fresh check is performed per network send regardless.
    public static let maximumAge: TimeInterval = 45

    public let balanceMicroUSD: Int64
    public let capturedAt: Date

    public init(balanceMicroUSD: Int64, capturedAt: Date) {
        self.balanceMicroUSD = balanceMicroUSD
        self.capturedAt = capturedAt
    }

    public var balanceUSD: Decimal { Decimal(balanceMicroUSD) / 1_000_000 }

    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age.isFinite && age >= -5 && age <= Self.maximumAge
    }
}

public enum ConsumerBalanceParser {
    /// Strictly decodes the documented BalanceResponse
    /// `{balance_micro_usd, balance_usd, withdrawable_micro_usd,
    /// withdrawable_usd}`. Only the integer micro-USD balance is trusted; the
    /// display strings are ignored. Missing, negative or malformed balance
    /// fails closed.
    public static func parse(_ data: Data, capturedAt: Date) throws -> ConsumerBalanceSnapshot {
        guard data.count <= ConsumerBalanceSnapshot.maximumResponseBytes else {
            throw ChatClientError.responseTooLarge
        }
        struct Envelope: Decodable {
            let balanceMicroUSD: Int64?

            enum CodingKeys: String, CodingKey {
                case balanceMicroUSD = "balance_micro_usd"
            }
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let balance = envelope.balanceMicroUSD,
              balance >= 0
        else { throw ChatClientError.invalidResponse }
        return ConsumerBalanceSnapshot(balanceMicroUSD: balance, capturedAt: capturedAt)
    }
}

public protocol ConsumerBalanceFetching: Sendable {
    func fetch(now: Date) async throws -> ConsumerBalanceSnapshot
}

/// Performs the authenticated balance read against the fixed network host
/// using the consumer API key supplied by the keychain-backed provider. The
/// key travels only in the Authorization header of this one request; it is
/// never logged, persisted, or reused as any other credential. A 401 is
/// reported as a key-specific rejection.
public struct ConsumerBalanceClient: ConsumerBalanceFetching, Sendable {
    private let consumerKeyProvider: @Sendable () async -> String?
    private let session: URLSession

    public init(
        consumerKeyProvider: @escaping @Sendable () async -> String?,
        session: URLSession? = nil
    ) {
        self.consumerKeyProvider = consumerKeyProvider
        self.session = session ?? ChatHTTPSession.shared
    }

    public func fetch(now: Date) async throws -> ConsumerBalanceSnapshot {
        guard let token = await consumerKeyProvider(), !token.isEmpty else {
            throw ChatClientError.missingConsumerKey
        }
        guard let url = URL(string: "https://api.darkbloom.dev/v1/payments/balance") else {
            throw ChatClientError.invalidEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            return try await ChatRouteExecutor.execute(
                request: request,
                session: session,
                successCapacity: ConsumerBalanceSnapshot.maximumResponseBytes
            ) { data in
                try ConsumerBalanceParser.parse(data, capturedAt: now)
            }
        } catch ChatClientError.unauthorized {
            throw ChatClientError.consumerKeyRejected
        }
    }
}

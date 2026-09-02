import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Authenticated account earnings")
struct AccountEarningsTests {
    @Test("decodes fractional and whole-second earning timestamps")
    func decodesObservedResponse() throws {
        let response = try AccountEarningsParser.parse(responseData)

        #expect(response.accountID == "acct-1")
        #expect(response.count == 2)
        #expect(response.earnings.map(\.amountMicroUSD) == [125_000, 25_000])
        #expect(abs(response.earnings[0].createdAt.timeIntervalSince1970 - 1_781_276_905.071) < 0.001)
        #expect(response.earnings[1].createdAt.timeIntervalSince1970 == 1_781_276_898)
    }

    @Test("rolling window includes its boundary and excludes older earnings")
    func sumsExactRollingWindow() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let response = AccountEarningsResponse(
            accountID: "acct-1",
            earnings: [
                earning(id: 1, microUSD: 500_000, at: now.addingTimeInterval(-86_400)),
                earning(id: 2, microUSD: 250_000, at: now.addingTimeInterval(-3_600)),
                earning(id: 3, microUSD: 999_000, at: now.addingTimeInterval(-86_401)),
            ],
            count: 3,
            historyLimit: 1_000,
            recentCount: 3
        )

        #expect(AccountEarningsParser.rolling24Hours(response, now: now) ==
            .available(microUSD: 750_000))
    }

    @Test("truncated recent history is never labeled as an actual 24-hour total")
    func rejectsIncompleteWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let response = AccountEarningsResponse(
            accountID: "acct-1",
            earnings: [earning(id: 1, microUSD: 500_000, at: now.addingTimeInterval(-60))],
            count: 1_001,
            historyLimit: 1_000,
            recentCount: 1_000
        )

        #expect(AccountEarningsParser.rolling24Hours(response, now: now) ==
            .unavailable(reason: "Account history does not cover the full 24-hour window"))
    }

    @Test("request is a fixed authenticated GET and its description redacts the token")
    func buildsSafeRequest() throws {
        let request = try AccountEarningsRequest.make(token: "secret-device-token", limit: 1_000)

        #expect(request.urlRequest.httpMethod == "GET")
        #expect(request.urlRequest.url?.absoluteString ==
            "https://api.darkbloom.dev/v1/provider/account-earnings?limit=1000")
        #expect(request.urlRequest.value(forHTTPHeaderField: "Authorization") ==
            "Bearer secret-device-token")
        #expect(request.description ==
            "GET https://api.darkbloom.dev/v1/provider/account-earnings?limit=1000 (authenticated)")
        #expect(!request.description.contains("secret-device-token"))
    }

    @Test("official pseudonym mapping links the authenticated account to its public 24-hour row")
    func derivesOfficialPseudonym() {
        #expect(DarkbloomAccountPseudonym.make(accountID: "acct-1") == "curious-satyr-9270")
    }

    @Test("public leaderboard supplies an exact server-computed rolling total")
    func readsExactLeaderboardWindow() throws {
        let data = Data("""
        {
          "metric": "earnings",
          "window": "24h",
          "updated_at": "2026-09-01T16:51:20Z",
          "entries": [
            {
              "rank": 101,
              "pseudonym": "curious-satyr-9270",
              "earnings_micro_usd": 2980837,
              "work_earnings_micro_usd": 2980837,
              "reward_earnings_micro_usd": 0,
              "tokens": 123,
              "jobs": 7709
            }
          ]
        }
        """.utf8)

        let window = try AccountLeaderboardParser.rolling24Hours(
            data,
            accountID: "acct-1"
        )

        #expect(window == .available(microUSD: 2_980_837))
        #expect(AccountLeaderboardRequest.make().url?.absoluteString ==
            "https://api.darkbloom.dev/v1/leaderboard?metric=earnings&window=24h&limit=200")
    }

    @Test("authenticated client falls back to the locally observed earnings window")
    func fallsBackToObservedWindow() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("DarkbloomObservedEarningsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".darkbloom", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("test-token".utf8).write(to: home.appendingPathComponent(".darkbloom/auth_token"))
        let database = try EarningsDatabase(url: home.appendingPathComponent("earnings.sqlite3"))
        try await database.ingest(AccountEarningsResponse(
            accountID: "acct-1",
            earnings: [earning(id: 1, microUSD: 100_000, at: now.addingTimeInterval(-43_200))],
            count: 1_000,
            historyLimit: 1_000,
            recentCount: 1_000,
            totalMicroUSD: 10_000_000
        ), capturedAt: now.addingTimeInterval(-43_200))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObservedEarningsURLProtocol.self]
        let client = AuthenticatedEarningsClient(
            homeDirectory: home,
            session: URLSession(configuration: configuration),
            database: database
        )

        let value = try await client.fetch(now: now)

        #expect(value == .observed(microUSD: 1_100_000, observedSeconds: 43_200))
    }

    private var responseData: Data {
        Data("""
        {
          "account_id": "acct-1",
          "count": 2,
          "earnings": [
            {
              "id": 1,
              "provider_id": "provider-1",
              "provider_key": "key-1",
              "model": "gemma",
              "amount_micro_usd": 125000,
              "prompt_tokens": 10,
              "completion_tokens": 20,
              "created_at": "2026-06-12T15:08:25.071033Z"
            },
            {
              "id": 2,
              "provider_id": "provider-1",
              "provider_key": "key-1",
              "model": "gemma",
              "amount_micro_usd": 25000,
              "prompt_tokens": 5,
              "completion_tokens": 10,
              "created_at": "2026-06-12T15:08:18Z"
            }
          ],
          "history_limit": 1000,
          "recent_count": 2,
          "total_micro_usd": 150000,
          "available_balance_micro_usd": 150000,
          "withdrawable_balance_micro_usd": 150000
        }
        """.utf8)
    }

    private func earning(id: Int64, microUSD: Int64, at date: Date) -> AccountEarning {
        AccountEarning(
            id: id,
            providerID: "provider-1",
            providerKey: "key-1",
            model: "gemma",
            amountMicroUSD: microUSD,
            promptTokens: 10,
            completionTokens: 20,
            createdAt: date
        )
    }
}

private final class ObservedEarningsURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data: Data
        if request.url?.path == "/v1/provider/account-earnings" {
            data = Data("""
            {
              "account_id": "acct-1",
              "count": 2000,
              "earnings": [{
                "id": 2,
                "provider_id": "provider-1",
                "provider_key": "key-1",
                "model": "gemma",
                "amount_micro_usd": 200000,
                "prompt_tokens": 10,
                "completion_tokens": 20,
                "created_at": "1970-01-24T03:33:20Z"
              }],
              "history_limit": 1000,
              "recent_count": 1000,
              "total_micro_usd": 11100000,
              "available_balance_micro_usd": 11100000,
              "withdrawable_balance_micro_usd": 11100000
            }
            """.utf8)
        } else {
            data = Data("""
            {"metric":"earnings","window":"24h","entries":[]}
            """.utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

import Foundation

public struct AccountEarningsRequest: CustomStringConvertible, Sendable {
    public let urlRequest: URLRequest

    public var description: String {
        "GET \(urlRequest.url?.absoluteString ?? "invalid-url") (authenticated)"
    }

    public static func make(token: String, limit: Int = 1_000) throws -> Self {
        guard !token.isEmpty else { throw AccountEarningsClientError.missingToken }
        guard limit > 0 else { throw AccountEarningsClientError.invalidHistoryLimit }

        var components = URLComponents(string: "https://api.darkbloom.dev/v1/provider/account-earnings")
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw AccountEarningsClientError.invalidEndpoint }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return Self(urlRequest: request)
    }
}

public enum AccountEarningsClientError: Error, LocalizedError, Equatable, Sendable {
    case missingToken
    case invalidHistoryLimit
    case invalidEndpoint
    case unauthorized
    case httpStatus(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingToken: "Not logged in — run darkbloom login"
        case .invalidHistoryLimit: "Invalid account earnings history limit"
        case .invalidEndpoint: "Invalid Darkbloom account earnings endpoint"
        case .unauthorized: "Darkbloom login expired — run darkbloom login"
        case .httpStatus(let status): "Darkbloom earnings request returned HTTP \(status)"
        case .invalidResponse: "Darkbloom earnings response was invalid"
        }
    }
}

public protocol AccountEarningsFetching: Sendable {
    func modelWorkEarnings(in range: DateInterval, calendar: Calendar) async throws -> [ModelWorkEarnings]
    func fetch(now: Date) async throws -> EarningsPresentationValue
    func jobCompletionSummary(now: Date, calendar: Calendar) async throws -> JobCompletionSummary?
    func todayEarningsSummary(now: Date, calendar: Calendar) async throws -> ObservedEarningsWindow?
    func weekEarningsSummary(now: Date, calendar: Calendar) async throws -> CalendarWeekEarningsSummary?
    func modelEarnings(since: Date) async throws -> [ModelEarnings]
    func activity(in range: DateInterval, unit: ActivityCalendarUnit, calendar: Calendar) async throws -> [ActivityBucket]?
    func modelActivity(in range: DateInterval, unit: ActivityCalendarUnit, calendar: Calendar, model: String?) async throws -> [ActivityBucket]?
    func activityModels(in range: DateInterval) async throws -> [String]
}

public extension AccountEarningsFetching {
    func modelWorkEarnings(in range: DateInterval, calendar: Calendar) async throws -> [ModelWorkEarnings] { [] }
    func modelActivity(in range: DateInterval, unit: ActivityCalendarUnit, calendar: Calendar, model: String?) async throws -> [ActivityBucket]? {
        guard model == nil else { return nil }
        return try await activity(in: range, unit: unit, calendar: calendar)
    }
    func activityModels(in range: DateInterval) async throws -> [String] { [] }
    func activity(in range: DateInterval, unit: ActivityCalendarUnit, calendar: Calendar) async throws -> [ActivityBucket]? { nil }
    func jobCompletionSummary(now: Date, calendar: Calendar) async throws -> JobCompletionSummary? {
        nil
    }

    func todayEarningsSummary(now: Date, calendar: Calendar) async throws -> ObservedEarningsWindow? {
        nil
    }

    func weekEarningsSummary(
        now: Date,
        calendar: Calendar
    ) async throws -> CalendarWeekEarningsSummary? {
        nil
    }

    func modelEarnings(since: Date) async throws -> [ModelEarnings] { [] }
}

public struct AuthenticatedEarningsClient: AccountEarningsFetching, Sendable {
    public func modelWorkEarnings(in range: DateInterval, calendar: Calendar) async throws -> [ModelWorkEarnings] {
        guard let database else { return [] }
        let models = try await database.activityModels(in: range)
        var values: [ModelWorkEarnings] = []
        for model in models {
            try Task.checkCancellation()
            values.append(try await database.modelWorkEarnings(model: model, in: range, calendar: calendar))
        }
        return values
    }
    public func modelActivity(in range: DateInterval, unit: ActivityCalendarUnit, calendar: Calendar, model: String?) async throws -> [ActivityBucket]? {
        try await database?.activity(in: range, unit: unit, calendar: calendar, model: model)
    }
    public func activityModels(in range: DateInterval) async throws -> [String] {
        try await database?.activityModels(in: range) ?? []
    }
    public func activity(in range: DateInterval, unit: ActivityCalendarUnit, calendar: Calendar) async throws -> [ActivityBucket]? {
        try await database?.activity(in: range, unit: unit, calendar: calendar)
    }

    private let tokenURL: URL
    private let session: URLSession
    private let historyLimit: Int
    private let database: EarningsDatabase?

    public init(
        homeDirectory: URL,
        session: URLSession = .shared,
        historyLimit: Int = 1_000,
        database: EarningsDatabase? = nil
    ) {
        tokenURL = homeDirectory.appendingPathComponent(".darkbloom/auth_token")
        self.session = session
        self.historyLimit = historyLimit
        self.database = database
    }

    public func fetch(now: Date) async throws -> EarningsPresentationValue {
        let token = try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try AccountEarningsRequest.make(token: token, limit: historyLimit)
        let (data, response) = try await session.data(for: request.urlRequest)
        try validate(response)
        let account = try AccountEarningsParser.parse(data)
        try await database?.ingest(account, capturedAt: now)

        let recentHistory = AccountEarningsParser.rolling24Hours(account, now: now)
        if case .available = recentHistory {
            return recentHistory
        }

        let leaderboardRequest = AccountLeaderboardRequest.make()
        let (leaderboardData, leaderboardResponse) = try await session.data(for: leaderboardRequest)
        try validate(leaderboardResponse)
        let leaderboard = try AccountLeaderboardParser.rolling24Hours(
            leaderboardData,
            accountID: account.accountID
        )
        if case .available = leaderboard {
            return leaderboard
        }
        if let observed = try await database?.observedEarningsWindow(endingAt: now) {
            return .observed(
                microUSD: observed.microUSD,
                observedSeconds: observed.observedSeconds
            )
        }
        return leaderboard
    }

    public func jobCompletionSummary(
        now: Date,
        calendar: Calendar
    ) async throws -> JobCompletionSummary? {
        try await database?.jobCompletionSummary(now: now, calendar: calendar)
    }

    public func todayEarningsSummary(
        now: Date,
        calendar: Calendar
    ) async throws -> ObservedEarningsWindow? {
        try await database?.todayEarningsSummary(now: now, calendar: calendar)
    }

    public func weekEarningsSummary(
        now: Date,
        calendar: Calendar
    ) async throws -> CalendarWeekEarningsSummary? {
        try await database?.weekEarningsSummary(now: now, calendar: calendar)
    }

    public func modelEarnings(since: Date) async throws -> [ModelEarnings] {
        try await database?.earningsByModel(since: since) ?? []
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AccountEarningsClientError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AccountEarningsClientError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AccountEarningsClientError.httpStatus(http.statusCode)
        }
    }
}

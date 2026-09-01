import Foundation

public enum AccountLeaderboardRequest {
    public static func make() -> URLRequest {
        var components = URLComponents(string: "https://api.darkbloom.dev/v1/leaderboard")!
        components.queryItems = [
            URLQueryItem(name: "metric", value: "earnings"),
            URLQueryItem(name: "window", value: "24h"),
            URLQueryItem(name: "limit", value: "200"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

public enum AccountLeaderboardParser {
    private struct Response: Decodable {
        let metric: String
        let window: String
        let entries: [Entry]
    }

    private struct Entry: Decodable {
        let pseudonym: String
        let earningsMicroUSD: Int64

        enum CodingKeys: String, CodingKey {
            case pseudonym
            case earningsMicroUSD = "earnings_micro_usd"
        }
    }

    public static func rolling24Hours(
        _ data: Data,
        accountID: String
    ) throws -> EarningsPresentationValue {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.metric == "earnings", response.window == "24h" else {
            return .unavailable(reason: "Darkbloom leaderboard did not return a 24-hour earnings window")
        }
        let pseudonym = DarkbloomAccountPseudonym.make(accountID: accountID)
        guard let entry = response.entries.first(where: { $0.pseudonym == pseudonym }) else {
            return .unavailable(reason: "Account is outside the public 24-hour leaderboard window")
        }
        return .available(microUSD: entry.earningsMicroUSD)
    }
}

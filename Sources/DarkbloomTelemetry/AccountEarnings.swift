import Foundation

public struct AccountEarning: Equatable, Sendable, Decodable {
    public let id: Int64
    public let providerID: String
    public let providerKey: String
    public let model: String
    public let amountMicroUSD: Int64
    public let promptTokens: Int
    public let completionTokens: Int
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, model
        case providerID = "provider_id"
        case providerKey = "provider_key"
        case amountMicroUSD = "amount_micro_usd"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case createdAt = "created_at"
    }

    public init(
        id: Int64,
        providerID: String,
        providerKey: String,
        model: String,
        amountMicroUSD: Int64,
        promptTokens: Int,
        completionTokens: Int,
        createdAt: Date
    ) {
        self.id = id
        self.providerID = providerID
        self.providerKey = providerKey
        self.model = model
        self.amountMicroUSD = amountMicroUSD
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.createdAt = createdAt
    }
}

public struct AccountEarningsResponse: Equatable, Sendable, Decodable {
    public let accountID: String
    public let earnings: [AccountEarning]
    public let count: Int64
    public let historyLimit: Int
    public let recentCount: Int
    public let totalMicroUSD: Int64
    public let availableBalanceMicroUSD: Int64
    public let withdrawableBalanceMicroUSD: Int64

    enum CodingKeys: String, CodingKey {
        case earnings, count
        case accountID = "account_id"
        case historyLimit = "history_limit"
        case recentCount = "recent_count"
        case totalMicroUSD = "total_micro_usd"
        case availableBalanceMicroUSD = "available_balance_micro_usd"
        case withdrawableBalanceMicroUSD = "withdrawable_balance_micro_usd"
    }

    public init(
        accountID: String,
        earnings: [AccountEarning],
        count: Int64,
        historyLimit: Int,
        recentCount: Int,
        totalMicroUSD: Int64 = 0,
        availableBalanceMicroUSD: Int64 = 0,
        withdrawableBalanceMicroUSD: Int64 = 0
    ) {
        self.accountID = accountID
        self.earnings = earnings
        self.count = count
        self.historyLimit = historyLimit
        self.recentCount = recentCount
        self.totalMicroUSD = totalMicroUSD
        self.availableBalanceMicroUSD = availableBalanceMicroUSD
        self.withdrawableBalanceMicroUSD = withdrawableBalanceMicroUSD
    }
}

public enum AccountEarningsParser {
    public static func parse(_ data: Data) throws -> AccountEarningsResponse {
        try decoder().decode(AccountEarningsResponse.self, from: data)
    }

    public static func rolling24Hours(
        _ response: AccountEarningsResponse,
        now: Date
    ) -> EarningsPresentationValue {
        let cutoff = now.addingTimeInterval(-86_400)
        let reachesCutoff = response.earnings.contains { $0.createdAt <= cutoff }
        let containsCompleteLifetime = response.count <= Int64(response.earnings.count)
        guard reachesCutoff || containsCompleteLifetime else {
            return .unavailable(reason: "Account history does not cover the full 24-hour window")
        }

        var total: Int64 = 0
        for earning in response.earnings where earning.createdAt >= cutoff && earning.createdAt <= now {
            let (next, overflow) = total.addingReportingOverflow(earning.amountMicroUSD)
            guard !overflow else {
                return .unavailable(reason: "Rolling earnings total is out of range")
            }
            total = next
        }
        return .available(microUSD: total)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = try? fractional.parse(value) {
                return date
            }
            if let date = try? wholeSeconds.parse(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unparseable account earning timestamp"
            )
        }
        return decoder
    }
}

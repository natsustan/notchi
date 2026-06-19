import Foundation

nonisolated struct CodexAPIAuth: Equatable {
    let accessToken: String
    let accountId: String?

    static func load(from data: Data) -> CodexAPIAuth? {
        guard let root = try? JSONDecoder().decode(AuthFile.self, from: data),
              let accessToken = root.tokens?.accessToken,
              !accessToken.isEmpty else {
            return nil
        }
        return CodexAPIAuth(accessToken: accessToken, accountId: root.tokens?.accountId)
    }

    private struct AuthFile: Decodable {
        let tokens: Tokens?
        struct Tokens: Decodable {
            let accessToken: String?
            let accountId: String?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountId = "account_id"
            }
        }
    }
}

nonisolated struct CodexAPIUsage: Equatable {
    let reviews: QuotaPeriod?
    let creditsBalance: Double?
}

nonisolated enum CodexUsageAPI {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static let creditUSDRate = 0.04

    static func authFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    static func makeRequest(auth: CodexAPIAuth) -> URLRequest {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = auth.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.timeoutInterval = 10
        return request
    }

    static func accessTokenExpiry(_ token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2,
              let payload = base64URLDecode(String(segments[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = json["exp"] as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    static func isAccessTokenExpired(_ token: String, now: Date) -> Bool {
        guard let expiry = accessTokenExpiry(token) else { return false }
        return expiry <= now
    }

    static func usage(from response: CodexUsageAPIResponse, now: Date) -> CodexAPIUsage {
        let reviews = response.codeReviewRateLimit?.primaryWindow.flatMap { window -> QuotaPeriod? in
            guard let usedPercent = window.usedPercent else { return nil }
            return QuotaPeriod(
                utilization: usedPercent.rounded(),
                resetDate: window.resetDate(now: now)
            )
        }

        let creditsBalance: Double?
        if let balance = response.credits?.balance {
            creditsBalance = balance
        } else if response.credits?.hasCredits == false {
            creditsBalance = 0
        } else {
            creditsBalance = nil
        }

        return CodexAPIUsage(reviews: reviews, creditsBalance: creditsBalance)
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

nonisolated struct CodexUsageAPIResponse: Decodable {
    let codeReviewRateLimit: RateLimit?
    let credits: Credits?

    enum CodingKeys: String, CodingKey {
        case codeReviewRateLimit = "code_review_rate_limit"
        case credits
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double?
        let resetAt: Double?
        let resetAfterSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case resetAfterSeconds = "reset_after_seconds"
        }

        func resetDate(now: Date) -> Date? {
            if let resetAt { return Date(timeIntervalSince1970: resetAt) }
            if let resetAfterSeconds { return now.addingTimeInterval(resetAfterSeconds) }
            return nil
        }
    }

    struct Credits: Decodable {
        let balance: Double?
        let hasCredits: Bool?

        enum CodingKeys: String, CodingKey {
            case balance
            case hasCredits = "has_credits"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = try container.decodeIfPresent(Bool.self, forKey: .hasCredits)
            if let number = try? container.decodeIfPresent(Double.self, forKey: .balance) {
                balance = number
            } else if let string = try? container.decodeIfPresent(String.self, forKey: .balance) {
                balance = Double(string)
            } else {
                balance = nil
            }
        }
    }
}

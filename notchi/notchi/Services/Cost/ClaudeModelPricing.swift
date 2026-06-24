import Foundation

struct ClaudeModelPricing: Equatable, Sendable {
    let inputPerToken: Double
    let outputPerToken: Double
    let cacheCreationPerToken: Double
    let cacheReadPerToken: Double
    let cacheCreation1hPerToken: Double?
    let thresholdTokens: Int?
    let inputPerTokenAboveThreshold: Double?
    let outputPerTokenAboveThreshold: Double?
    let cacheCreationPerTokenAboveThreshold: Double?
    let cacheReadPerTokenAboveThreshold: Double?
}

protocol ClaudePricingProviding: Sendable {
    func pricing(model: String, on date: Date) -> ClaudeModelPricing?
}

enum CostPricing {
    /// Strips date suffix and provider prefix: "anthropic/claude-sonnet-4-20250514" → "claude-sonnet-4".
    static func normalizeClaudeModel(_ raw: String) -> String {
        var s = raw
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        // drop a trailing -YYYYMMDD date stamp
        if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) { s.removeSubrange(r) }
        return s
    }

    static func claudeCostUSD(
        model: String, input: Int, cacheRead: Int, cacheCreation: Int,
        cacheCreation1h: Int, output: Int, pricing: ClaudeModelPricing) -> Double?
    {
        let contextTokens = input + cacheRead + cacheCreation
        let useAbove = (pricing.thresholdTokens.map { contextTokens > $0 } ?? false)
            && pricing.inputPerTokenAboveThreshold != nil

        let inP = useAbove ? (pricing.inputPerTokenAboveThreshold ?? pricing.inputPerToken) : pricing.inputPerToken
        let outP = useAbove ? (pricing.outputPerTokenAboveThreshold ?? pricing.outputPerToken) : pricing.outputPerToken
        let crP = useAbove ? (pricing.cacheCreationPerTokenAboveThreshold ?? pricing.cacheCreationPerToken) : pricing.cacheCreationPerToken
        let rdP = useAbove ? (pricing.cacheReadPerTokenAboveThreshold ?? pricing.cacheReadPerToken) : pricing.cacheReadPerToken

        // cacheCreation1h is a subset of cacheCreation priced at a separate rate when available.
        let standardCreate = max(0, cacheCreation - cacheCreation1h)
        let create1hCost = Double(cacheCreation1h) * (pricing.cacheCreation1hPerToken ?? crP)

        return Double(input) * inP
            + Double(output) * outP
            + Double(standardCreate) * crP
            + create1hCost
            + Double(cacheRead) * rdP
    }
}

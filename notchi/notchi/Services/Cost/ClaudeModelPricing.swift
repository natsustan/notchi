import Foundation

nonisolated struct ClaudeModelPricing: Equatable, Sendable {
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
    nonisolated func pricing(model: String, on date: Date) -> ClaudeModelPricing?
}

nonisolated enum CostPricing {
    static func normalizeClaudeModel(_ raw: String) -> String {
        var s = raw
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
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

        let standardCreate = max(0, cacheCreation - cacheCreation1h)
        let create1hCost = Double(cacheCreation1h) * (pricing.cacheCreation1hPerToken ?? crP)

        return Double(input) * inP
            + Double(output) * outP
            + Double(standardCreate) * crP
            + create1hCost
            + Double(cacheRead) * rdP
    }
}

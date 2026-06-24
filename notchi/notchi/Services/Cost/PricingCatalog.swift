import Foundation

final class PricingCatalog: ClaudePricingProviding, @unchecked Sendable {
    private struct Snapshot: Decodable {
        let version: Int
        let models: [String: ClaudeModelPricingDTO]
    }

    private struct ClaudeModelPricingDTO: Decodable {
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

        func toPricing() -> ClaudeModelPricing {
            ClaudeModelPricing(
                inputPerToken: inputPerToken,
                outputPerToken: outputPerToken,
                cacheCreationPerToken: cacheCreationPerToken,
                cacheReadPerToken: cacheReadPerToken,
                cacheCreation1hPerToken: cacheCreation1hPerToken,
                thresholdTokens: thresholdTokens,
                inputPerTokenAboveThreshold: inputPerTokenAboveThreshold,
                outputPerTokenAboveThreshold: outputPerTokenAboveThreshold,
                cacheCreationPerTokenAboveThreshold: cacheCreationPerTokenAboveThreshold,
                cacheReadPerTokenAboveThreshold: cacheReadPerTokenAboveThreshold)
        }
    }

    // models.dev /api.json shape — only the fields we need
    private struct ModelsDev: Decodable {
        let anthropic: ModelsDev.Provider?

        struct Provider: Decodable {
            let models: [String: ModelsDev.ModelEntry]
        }

        struct ModelEntry: Decodable {
            let cost: ModelsDev.Cost?
        }

        struct Cost: Decodable {
            let input: Double
            let output: Double
            let cache_read: Double
            let cache_write: Double
            let tiers: [ModelsDev.Tier]?
        }

        struct Tier: Decodable {
            let input: Double
            let output: Double
            let cache_read: Double
            let cache_write: Double
            let tier: ModelsDev.TierSpec?
        }

        struct TierSpec: Decodable {
            let type: String
            let size: Int
        }
    }

    private let lock = NSLock()
    private var table: [String: ClaudeModelPricing]

    init(fallbackBundle: Bundle) {
        table = Self.loadFallback(bundle: fallbackBundle)
    }

    private static func loadFallback(bundle: Bundle) -> [String: ClaudeModelPricing] {
        guard let url = bundle.url(forResource: "claude-pricing-fallback", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return [:] }
        return snap.models.mapValues { $0.toPricing() }
    }

    func pricing(model: String, on date: Date) -> ClaudeModelPricing? {
        let key = CostPricing.normalizeClaudeModel(model)
        lock.lock(); defer { lock.unlock() }
        return table[key]
    }

    func refreshFromNetwork() async {
        guard let url = URL(string: "https://models.dev/api.json") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        guard let decoded = try? JSONDecoder().decode(ModelsDev.self, from: data),
              let provider = decoded.anthropic else { return }

        let perMillion = 1_000_000.0
        var updated: [String: ClaudeModelPricing] = [:]

        for (rawId, entry) in provider.models {
            guard let cost = entry.cost else { continue }
            let key = CostPricing.normalizeClaudeModel(rawId)

            // Extract tier pricing when the first tier is a context-size threshold
            let firstTier = cost.tiers?.first(where: { $0.tier?.type == "context" })
            let thresholdTokens = firstTier?.tier?.size

            updated[key] = ClaudeModelPricing(
                inputPerToken: cost.input / perMillion,
                outputPerToken: cost.output / perMillion,
                cacheCreationPerToken: cost.cache_write / perMillion,
                cacheReadPerToken: cost.cache_read / perMillion,
                cacheCreation1hPerToken: nil,
                thresholdTokens: thresholdTokens,
                inputPerTokenAboveThreshold: firstTier.map { $0.input / perMillion },
                outputPerTokenAboveThreshold: firstTier.map { $0.output / perMillion },
                cacheCreationPerTokenAboveThreshold: firstTier.map { $0.cache_write / perMillion },
                cacheReadPerTokenAboveThreshold: firstTier.map { $0.cache_read / perMillion })
        }

        guard Self.isPlausibleRefresh(updated) else { return }
        replaceTable(updated)
    }

    private func replaceTable(_ updated: [String: ClaudeModelPricing]) {
        lock.lock(); defer { lock.unlock() }
        table = updated
    }

    // Symmetric prefix checks: models.dev may key Sonnet/Opus with version suffixes
    // (e.g. claude-sonnet-4-5), so an exact-key match would silently reject every refresh.
    static func isPlausibleRefresh(_ candidate: [String: ClaudeModelPricing]) -> Bool {
        let hasSonnet4Family = candidate.keys.contains(where: { $0.hasPrefix("claude-sonnet-4") })
        let hasOpus4Family = candidate.keys.contains(where: { $0.hasPrefix("claude-opus-4") })
        return hasSonnet4Family && hasOpus4Family
    }
}

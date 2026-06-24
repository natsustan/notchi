import XCTest
@testable import notchi

final class ClaudeModelPricingTests: XCTestCase {
    // Named constants = independent expectations (per-MILLION → per-token)
    private let sonnetInput = 3.0 / 1_000_000
    private let sonnetOutput = 15.0 / 1_000_000
    private let sonnetCacheRead = 0.30 / 1_000_000
    private let sonnetCacheWrite = 3.75 / 1_000_000

    private func pricing() -> ClaudeModelPricing {
        ClaudeModelPricing(
            inputPerToken: sonnetInput, outputPerToken: sonnetOutput,
            cacheCreationPerToken: sonnetCacheWrite, cacheReadPerToken: sonnetCacheRead,
            cacheCreation1hPerToken: nil,
            thresholdTokens: 200_000,
            inputPerTokenAboveThreshold: 6.0 / 1_000_000,
            outputPerTokenAboveThreshold: 22.5 / 1_000_000,
            cacheCreationPerTokenAboveThreshold: 7.5 / 1_000_000,
            cacheReadPerTokenAboveThreshold: 0.60 / 1_000_000)
    }

    func testNormalizesProviderPrefixedModelNames() {
        XCTAssertEqual(CostPricing.normalizeClaudeModel("claude-sonnet-4-20250514"), "claude-sonnet-4")
        XCTAssertEqual(CostPricing.normalizeClaudeModel("anthropic/claude-opus-4-1"), "claude-opus-4-1")
    }

    func testCostBelowThresholdSumsEachTokenClass() {
        let cost = CostPricing.claudeCostUSD(
            model: "claude-sonnet-4", input: 1_000, cacheRead: 2_000,
            cacheCreation: 500, cacheCreation1h: 0, output: 800, pricing: pricing())
        let inputCost: Double = 1_000 * sonnetInput
        let readCost: Double = 2_000 * sonnetCacheRead
        let writeCost: Double = 500 * sonnetCacheWrite
        let outputCost: Double = 800 * sonnetOutput
        let expected: Double = inputCost + readCost + writeCost + outputCost
        XCTAssertEqual(cost!, expected, accuracy: 1e-12)
    }

    func testWholeRequestRepricedWhenContextExceedsThreshold() {
        // input context = input + cacheRead + cacheCreation = 250_000 > 200_000 → above-threshold rates apply to ALL classes
        let cost = CostPricing.claudeCostUSD(
            model: "claude-sonnet-4", input: 50_000, cacheRead: 150_000,
            cacheCreation: 50_000, cacheCreation1h: 0, output: 1_000, pricing: pricing())
        let inputCost: Double = 50_000 * (6.0 / 1_000_000)
        let readCost: Double = 150_000 * (0.60 / 1_000_000)
        let writeCost: Double = 50_000 * (7.5 / 1_000_000)
        let outputCost: Double = 1_000 * (22.5 / 1_000_000)
        let expected: Double = inputCost + readCost + writeCost + outputCost
        XCTAssertEqual(cost!, expected, accuracy: 1e-9)
    }

    func testCatalogFallsBackToEmbeddedSnapshotForKnownModel() {
        let catalog = PricingCatalog(fallbackBundle: .main)
        let p = catalog.pricing(model: "claude-sonnet-4", on: Date())
        XCTAssertNotNil(p, "embedded fallback must price the current Sonnet model")
        XCTAssertGreaterThan(p!.outputPerToken, p!.inputPerToken)
    }

    func testCatalogReturnsNilForUnknownModel() {
        let catalog = PricingCatalog(fallbackBundle: .main)
        XCTAssertNil(catalog.pricing(model: "totally-made-up-model", on: Date()))
    }

    func testPlausibilityGuardAcceptsBothAnchorsAndRejectsPartial() {
        let anyPricing = ClaudeModelPricing(
            inputPerToken: sonnetInput, outputPerToken: sonnetOutput,
            cacheCreationPerToken: sonnetCacheWrite, cacheReadPerToken: sonnetCacheRead,
            cacheCreation1hPerToken: nil, thresholdTokens: nil,
            inputPerTokenAboveThreshold: nil, outputPerTokenAboveThreshold: nil,
            cacheCreationPerTokenAboveThreshold: nil, cacheReadPerTokenAboveThreshold: nil)

        // Versioned anchor keys must still pass (prefix match, not exact key).
        let bothAnchors = ["claude-sonnet-4-5": anyPricing, "claude-opus-4-1": anyPricing]
        XCTAssertTrue(PricingCatalog.isPlausibleRefresh(bothAnchors))

        let sonnetOnly = ["claude-sonnet-4": anyPricing]
        XCTAssertFalse(PricingCatalog.isPlausibleRefresh(sonnetOnly))

        XCTAssertFalse(PricingCatalog.isPlausibleRefresh([:]))
    }
}

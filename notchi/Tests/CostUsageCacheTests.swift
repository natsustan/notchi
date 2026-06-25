import XCTest
@testable import notchi

final class CostUsageCacheTests: XCTestCase {
    func testLoadDiscardsCacheWithStaleVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cache.json")
        var stale = CostUsageCache(version: CostUsageCache.currentVersion - 1, files: [:], buckets: [:])
        stale.buckets["2026-06-24"] = ["claude-opus-4": ModelTokenTotals(input: 1)]
        try JSONEncoder().encode(stale).write(to: url)

        let loaded = CostUsageCacheStore.load(url: url)
        XCTAssertEqual(loaded.version, CostUsageCache.currentVersion)
        XCTAssertTrue(loaded.buckets.isEmpty, "stale-version cache must be discarded")
    }

    func testSaveThenLoadRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cache.json")
        var cache = CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:])
        cache.buckets["2026-06-24"] = ["claude-opus-4": ModelTokenTotals(input: 5, output: 7, costNanos: 12)]
        CostUsageCacheStore.save(cache, to: url)
        let loaded = CostUsageCacheStore.load(url: url)
        XCTAssertEqual(loaded.buckets["2026-06-24"]?["claude-opus-4"]?.input, 5)
    }
}

import XCTest
@testable import notchi

final class CostHistoryStoreTests: XCTestCase {
    @MainActor
    func testStorePublishesReportFromInjectedScan() async {
        var buckets: DayModelBuckets = [:]
        buckets[DailyCostReport.dayKey(Date(), calendar: .current)] =
            ["claude-opus-4": ModelTokenTotals(input: 10, output: 5, costNanos: 3_000_000_000,
                                               requestCount: 1, pricedCount: 1)]
        let store = CostHistoryStore(windowDays: 30, calendar: .current,
            scanProvider: { _ in buckets })
        await store.refresh()
        XCTAssertEqual(store.report?.todayCostUSD ?? 0, 3.0, accuracy: 1e-9)
        XCTAssertEqual(store.report?.topModel, "claude-opus-4")
        XCTAssertFalse(store.isScanning)
    }
}

final class DailyCostReportTests: XCTestCase {
    private func day(_ s: String) -> Date {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    func testReportDerivesHeadlineStatsAndGapFills() {
        var buckets: DayModelBuckets = [:]
        buckets["2026-06-22"] = ["claude-sonnet-4": ModelTokenTotals(
            input: 100, output: 50, costNanos: 2_000_000_000, requestCount: 1, pricedCount: 1)]
        buckets["2026-06-24"] = [
            "claude-opus-4": ModelTokenTotals(
                input: 300, output: 100, costNanos: 9_000_000_000, requestCount: 2, pricedCount: 2),
            "claude-sonnet-4": ModelTokenTotals(
                input: 200, output: 20, costNanos: 1_000_000_000, requestCount: 1, pricedCount: 1)]

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let report = DailyCostReport.make(
            provider: .claude, buckets: buckets,
            window: DateInterval(start: day("2026-06-20"), end: day("2026-06-24")),
            today: day("2026-06-24"), calendar: cal)

        // window 06-20..06-24 → gap-filled ascending indices: 0=20, 1=21, 2=22, 3=23, 4=24
        XCTAssertEqual(report.entries.count, 5)
        XCTAssertEqual(report.entries[1].costUSD, 0, accuracy: 1e-9)   // 21st: no activity
        XCTAssertEqual(report.entries[2].costUSD, 2.0, accuracy: 1e-9) // 22nd: $2
        XCTAssertEqual(report.windowCostUSD, 12.0, accuracy: 1e-9)     // 2 + 9 + 1
        XCTAssertEqual(report.windowTokens, 100 + 50 + 300 + 100 + 200 + 20)
        XCTAssertEqual(report.todayCostUSD, 10.0, accuracy: 1e-9)      // 24th: 9 + 1
        XCTAssertEqual(report.latestTokens, 300 + 100 + 200 + 20)      // most recent active day = 24th
        XCTAssertEqual(report.topModel, "claude-opus-4")              // highest cost across window
    }
}

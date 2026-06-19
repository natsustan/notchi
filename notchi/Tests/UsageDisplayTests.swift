import XCTest
@testable import notchi

final class UsageDisplayTests: XCTestCase {
    private let futureReset = Date(timeIntervalSince1970: 4_102_444_800)

    func testPercentLeftIsComplementOfUsed() {
        XCTAssertEqual(UsageMetrics.percentLeft(fromPercentUsed: 42), 58)
        XCTAssertEqual(UsageMetrics.percentLeft(fromPercentUsed: 0), 100)
        XCTAssertEqual(UsageMetrics.percentLeft(fromPercentUsed: 100), 0)
    }

    func testPercentLeftClampsBeyondBounds() {
        XCTAssertEqual(UsageMetrics.percentLeft(fromPercentUsed: 125), 0)
        XCTAssertEqual(UsageMetrics.percentLeft(fromPercentUsed: -10), 100)
    }

    func testPeriodDisplayReturnsNilWhenNoUsage() {
        XCTAssertNil(UsageMetrics.periodDisplay(title: "Session", usage: nil))
    }

    func testPeriodDisplayIncludesResetTextWhenResetInFuture() {
        let usage = QuotaPeriod(utilization: 58, resetDate: futureReset)

        let display = UsageMetrics.periodDisplay(title: "Weekly", usage: usage)

        XCTAssertEqual(display?.title, "Weekly")
        XCTAssertEqual(display?.percentUsed, 58)
        XCTAssertEqual(display?.resetText?.hasPrefix("Resets in "), true)
    }

    func testPeriodDisplayOmitsResetTextWhenExpired() {
        let usage = QuotaPeriod(utilization: 90, resetDate: Date(timeIntervalSince1970: 1_000))

        let display = UsageMetrics.periodDisplay(title: "Session", usage: usage)

        XCTAssertEqual(display?.percentUsed, 90)
        XCTAssertNil(display?.resetText)
    }

    func testPeriodDisplayClampsUtilizationAboveQuota() {
        let usage = QuotaPeriod(utilization: 137, resetDate: futureReset)

        XCTAssertEqual(UsageMetrics.periodDisplay(title: "Session", usage: usage)?.percentUsed, 100)
    }

    func testExtraUsageDisplayReturnsNilWhenDisabled() {
        let extra = ExtraUsage(isEnabled: false, monthlyLimit: 20, usedCredits: 4.2, utilization: nil)
        XCTAssertNil(UsageMetrics.extraUsageDisplay(extra))
    }

    func testExtraUsageDisplayReturnsNilWhenLimitMissing() {
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: nil, usedCredits: 4.2, utilization: nil)
        XCTAssertNil(UsageMetrics.extraUsageDisplay(extra))
    }

    func testExtraUsageDisplayComputesPercentUsed() {
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: 20, usedCredits: 5, utilization: nil)

        let display = UsageMetrics.extraUsageDisplay(extra)

        XCTAssertEqual(display?.usedCredits, 5)
        XCTAssertEqual(display?.monthlyLimit, 20)
        XCTAssertEqual(display?.percentUsed, 25)
    }

    func testClaudeHasDataTrueWhenAnyPeriodOrExtraUsagePresent() {
        let usage = QuotaPeriod(utilization: 10, resetDate: futureReset)
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: 20, usedCredits: 5, utilization: nil)

        XCTAssertTrue(UsageMetrics.claudeHasData(usage: usage, weeklyUsage: nil, extraUsage: nil))
        XCTAssertTrue(UsageMetrics.claudeHasData(usage: nil, weeklyUsage: usage, extraUsage: nil))
        XCTAssertTrue(UsageMetrics.claudeHasData(usage: nil, weeklyUsage: nil, extraUsage: extra))
    }

    func testClaudeHasDataFalseWhenNoUsableData() {
        let disabledExtra = ExtraUsage(isEnabled: false, monthlyLimit: 20, usedCredits: 5, utilization: nil)
        XCTAssertFalse(UsageMetrics.claudeHasData(usage: nil, weeklyUsage: nil, extraUsage: disabledExtra))
    }

    func testCodexHasDataReflectsPeriodPresence() {
        let usage = QuotaPeriod(utilization: 10, resetDate: futureReset)
        XCTAssertTrue(UsageMetrics.codexHasData(usage: usage, weeklyUsage: nil))
        XCTAssertTrue(UsageMetrics.codexHasData(usage: nil, weeklyUsage: usage))
        XCTAssertFalse(UsageMetrics.codexHasData(usage: nil, weeklyUsage: nil))
    }

    func testCurrencyFormatsWholeAndFractionalAmounts() {
        XCTAssertEqual(ExtraUsageRowView.currency(20), "$20")
        XCTAssertEqual(ExtraUsageRowView.currency(4.2), "$4.20")
    }
}

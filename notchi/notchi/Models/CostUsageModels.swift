import Foundation

enum CostProvider: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
}

struct ModelTokenTotals: Equatable, Sendable, Codable {
    var input: Int = 0
    var cacheRead: Int = 0
    var cacheCreation: Int = 0
    var cacheCreation1h: Int = 0
    var output: Int = 0
    var costNanos: Int = 0           // USD × 1_000_000_000 (integer to avoid float drift)
    var requestCount: Int = 0
    var pricedCount: Int = 0

    var totalTokens: Int { input + cacheRead + cacheCreation + output }
    var costUSD: Double { Double(costNanos) / 1_000_000_000 }

    static func + (l: ModelTokenTotals, r: ModelTokenTotals) -> ModelTokenTotals {
        ModelTokenTotals(
            input: l.input + r.input, cacheRead: l.cacheRead + r.cacheRead,
            cacheCreation: l.cacheCreation + r.cacheCreation,
            cacheCreation1h: l.cacheCreation1h + r.cacheCreation1h,
            output: l.output + r.output, costNanos: l.costNanos + r.costNanos,
            requestCount: l.requestCount + r.requestCount, pricedCount: l.pricedCount + r.pricedCount)
    }
}

typealias DayModelBuckets = [String: [String: ModelTokenTotals]]  // [dayKey: [model: totals]]

struct DailyCostReport: Equatable, Sendable {
    struct DayEntry: Equatable, Sendable, Identifiable {
        let day: String          // "yyyy-MM-dd"
        let date: Date
        let costUSD: Double
        let totalTokens: Int
        let requestCount: Int
        let pricedFraction: Double   // 0...1; 1 = every request priced
        var id: String { day }
    }

    let provider: CostProvider
    let entries: [DayEntry]      // ascending by date, gap-filled across window
    let topModel: String?

    var windowCostUSD: Double { entries.reduce(0) { $0 + $1.costUSD } }
    var windowTokens: Int { entries.reduce(0) { $0 + $1.totalTokens } }
    var todayCostUSD: Double { entries.last?.costUSD ?? 0 }
    var latestTokens: Int { entries.last(where: { $0.totalTokens > 0 })?.totalTokens ?? 0 }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func make(
        provider: CostProvider, buckets: DayModelBuckets,
        window: DateInterval, today: Date, calendar: Calendar) -> DailyCostReport
    {
        // 1) gap-filled ascending day list across [window.start, today]
        var entries: [DayEntry] = []
        var cursor = calendar.startOfDay(for: window.start)
        let last = calendar.startOfDay(for: today)
        var modelCostNanos: [String: Int] = [:]
        while cursor <= last {
            let key = dayKey(cursor, calendar: calendar)
            let models = buckets[key] ?? [:]
            var totals = ModelTokenTotals()
            for (m, t) in models {
                totals = totals + t
                modelCostNanos[m, default: 0] += t.costNanos
            }
            let priced = totals.requestCount == 0 ? 1 : Double(totals.pricedCount) / Double(totals.requestCount)
            entries.append(DayEntry(
                day: key, date: cursor, costUSD: totals.costUSD,
                totalTokens: totals.totalTokens, requestCount: totals.requestCount,
                pricedFraction: priced))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        let topModel = modelCostNanos.max(by: { $0.value < $1.value })?.key
        return DailyCostReport(provider: provider, entries: entries, topModel: topModel)
    }
}

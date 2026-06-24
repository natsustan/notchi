import Foundation
import Observation

@MainActor
@Observable
final class CostHistoryStore {
    private(set) var report: DailyCostReport?
    private(set) var isScanning = false
    private(set) var lastScan: Date?

    private let windowDays: Int
    private let calendar: Calendar
    private let scanProvider: @Sendable (Date) async -> DayModelBuckets
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 90

    init(windowDays: Int = 30, calendar: Calendar = .current,
         scanProvider: @escaping @Sendable (Date) async -> DayModelBuckets) {
        self.windowDays = windowDays
        self.calendar = calendar
        self.scanProvider = scanProvider
    }

    /// Production initializer — builds scanProvider from real scanner + cache.
    convenience init(windowDays: Int = 30, calendar: Calendar = .current,
                     pricing: any ClaudePricingProviding,
                     projectsRoots: [URL],
                     cacheURL: URL) {
        // Construct scanner once; closure captures it and calls scan() serially (one at a time via isScanning guard).
        let scanner = ClaudeCostScanner(
            projectsRoots: projectsRoots,
            pricing: pricing,
            windowDays: windowDays,
            calendar: calendar)

        self.init(windowDays: windowDays, calendar: calendar) { now in
            await Task.detached(priority: .utility) {
                let cache = CostUsageCacheStore.load(url: cacheURL)
                let updated = scanner.scan(cache: cache, now: now)
                CostUsageCacheStore.save(updated, to: cacheURL)
                return updated.buckets
            }.value
        }
    }

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        if isScanning { return }
        isScanning = true
        let now = Date()
        let buckets = await scanProvider(now)
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1),
                                        to: calendar.startOfDay(for: now))!
        report = DailyCostReport.make(
            provider: .claude, buckets: buckets,
            window: DateInterval(start: windowStart, end: now),
            today: now, calendar: calendar)
        lastScan = now
        isScanning = false
    }
}

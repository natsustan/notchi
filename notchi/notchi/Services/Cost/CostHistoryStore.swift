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
    private let pricingCatalog: PricingCatalog?

    init(windowDays: Int = 30, calendar: Calendar = .current,
         scanProvider: @escaping @Sendable (Date) async -> DayModelBuckets) {
        self.windowDays = windowDays
        self.calendar = calendar
        self.scanProvider = scanProvider
        self.pricingCatalog = nil
    }

    convenience init(windowDays: Int = 30, calendar: Calendar = .current,
                     pricing: PricingCatalog,
                     projectsRoots: [URL],
                     cacheURL: URL) {
        let scanner = ClaudeCostScanner(
            projectsRoots: projectsRoots,
            pricing: pricing,
            windowDays: windowDays,
            calendar: calendar)

        self.init(windowDays: windowDays, calendar: calendar, pricingCatalog: pricing) { now in
            await Task.detached(priority: .utility) {
                let sig = pricing.signature()
                let cache = CostUsageCacheStore.load(url: cacheURL).reconciled(withPricingSignature: sig)
                var updated = scanner.scan(cache: cache, now: now)
                updated.pricingSignature = sig
                CostUsageCacheStore.save(updated, to: cacheURL)
                return updated.buckets
            }.value
        }
    }

    private init(windowDays: Int, calendar: Calendar, pricingCatalog: PricingCatalog,
                 scanProvider: @escaping @Sendable (Date) async -> DayModelBuckets) {
        self.windowDays = windowDays
        self.calendar = calendar
        self.scanProvider = scanProvider
        self.pricingCatalog = pricingCatalog
    }

    func start() {
        guard timer == nil else { return }
        if let catalog = pricingCatalog {
            Task.detached(priority: .utility) { await catalog.refreshFromNetwork() }
        }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        if isScanning { return }
        isScanning = true
        defer { isScanning = false }
        let now = Date()
        let buckets = await scanProvider(now)
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1),
                                        to: calendar.startOfDay(for: now))!
        report = DailyCostReport.make(
            provider: .claude, buckets: buckets,
            windowStart: windowStart, today: now, calendar: calendar)
        lastScan = now
    }
}

// MARK: - Shared singleton

extension CostHistoryStore {
    static let shared: CostHistoryStore = {
        let pricing = PricingCatalog(fallbackBundle: .main,
                                     snapshotURL: PricingCatalog.defaultSnapshotURL())
        let projectsRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let cacheURL: URL
        if let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            cacheURL = cachesDir.appendingPathComponent("CostUsage/claude.json")
        } else {
            cacheURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".notchi/CostUsage/claude.json")
        }
        return CostHistoryStore(pricing: pricing, projectsRoots: [projectsRoot], cacheURL: cacheURL)
    }()
}

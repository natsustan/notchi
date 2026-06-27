import Foundation

nonisolated struct CostUsageCache: Codable, Equatable {
    nonisolated struct CodexResume: Codable, Equatable {
        var model: String?
        var baseInput: Int?
        var baseCached: Int?
        var baseOutput: Int?
    }

    nonisolated struct FileState: Codable, Equatable {
        var size: Int64
        var mtime: Double
        var offset: Int64
        var codexResume: CodexResume? = nil
    }

    static let currentVersion = 1
    var version: Int
    var files: [String: FileState]
    var buckets: DayModelBuckets
    var pricingSignature: String? = nil

    func reconciled(withPricingSignature signature: String) -> CostUsageCache {
        pricingSignature == signature
            ? self
            : CostUsageCache(version: Self.currentVersion, files: [:], buckets: [:], pricingSignature: signature)
    }
}

nonisolated enum CostUsageCacheStore {
    static func load(url: URL) -> CostUsageCache {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CostUsageCache.self, from: data),
              decoded.version == CostUsageCache.currentVersion
        else { return CostUsageCache(version: CostUsageCache.currentVersion, files: [:], buckets: [:], pricingSignature: nil) }
        return decoded
    }

    static func save(_ cache: CostUsageCache, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard let data = try? JSONEncoder().encode(cache), (try? data.write(to: tmp, options: .atomic)) != nil
        else { return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

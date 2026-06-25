import Foundation

nonisolated final class CodexCostScanner {
    let projectsRoots: [URL]
    let pricing: any ClaudePricingProviding
    let windowDays: Int
    let calendar: Calendar

    nonisolated(unsafe) private var seen = Set<String>()

    nonisolated(unsafe) private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private let isoPlain = ISO8601DateFormatter()

    nonisolated init(projectsRoots: [URL], pricing: any ClaudePricingProviding, windowDays: Int, calendar: Calendar) {
        self.projectsRoots = projectsRoots
        self.pricing = pricing
        self.windowDays = windowDays
        self.calendar = calendar
    }

    nonisolated deinit {}

    nonisolated func scan(cache input: CostUsageCache, now: Date) -> CostUsageCache {
        seen.removeAll()
        var cache = input
        if anyTrackedFileShrank(cache.files) {
            cache.files = [:]
            cache.buckets = [:]
        }
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1),
                                        to: calendar.startOfDay(for: now))!
        let sinceKey = DailyCostReport.dayKey(windowStart, calendar: calendar)

        for root in projectsRoots {
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let path = url.path
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0
                var state = cache.files[path] ?? .init(size: 0, mtime: 0, offset: 0)
                if state.size == size, state.mtime == mtime { continue }
                let startOffset = (size >= state.size) ? state.offset : 0

                state.offset = parseFile(url: url, startOffset: startOffset, sinceKey: sinceKey, into: &cache.buckets)
                state.size = size
                state.mtime = mtime
                cache.files[path] = state
            }
        }
        cache.buckets = cache.buckets.filter { $0.key >= sinceKey }
        return cache
    }

    nonisolated private func anyTrackedFileShrank(_ files: [String: CostUsageCache.FileState]) -> Bool {
        for (path, state) in files {
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
            if size < state.size { return true }
        }
        return false
    }

    nonisolated private func parseFile(url: URL, startOffset: Int64, sinceKey: String,
                                       into buckets: inout DayModelBuckets) -> Int64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return startOffset }
        defer { try? handle.close() }
        if startOffset > 0 { try? handle.seek(toOffset: UInt64(startOffset)) }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return startOffset }

        var consumed = startOffset
        var lineStart = data.startIndex
        let newline = UInt8(ascii: "\n")
        var i = data.startIndex
        var currentModel: String? = nil
        var runningBaseline: (input: Int, cached: Int, output: Int)? = nil
        while i < data.endIndex {
            if data[i] == newline {
                let lineData = data[lineStart..<i]
                consumed += Int64(lineData.count) + 1
                handleLine(lineData, sinceKey: sinceKey, currentModel: &currentModel,
                           runningBaseline: &runningBaseline, into: &buckets)
                lineStart = data.index(after: i)
            }
            i = data.index(after: i)
        }
        return consumed
    }

    nonisolated private func handleLine(_ lineData: Data, sinceKey: String,
                                        currentModel: inout String?,
                                        runningBaseline: inout (input: Int, cached: Int, output: Int)?,
                                        into buckets: inout DayModelBuckets) {
        guard lineData.range(of: Data(#""type""#.utf8)) != nil else { return }
        guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
              let type_ = obj["type"] as? String else { return }

        if type_ == "turn_context" {
            if let payload = obj["payload"] as? [String: Any],
               let model = payload["model"] as? String {
                currentModel = model
            }
            return
        }

        guard type_ == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let ts = obj["timestamp"] as? String,
              let date = parseTimestamp(ts) else { return }

        let dayKey = DailyCostReport.dayKey(date, calendar: calendar)
        guard dayKey >= sinceKey else { return }

        guard let info = payload["info"] as? [String: Any] else { return }
        let last = info["last_token_usage"] as? [String: Any]
        let total = info["total_token_usage"] as? [String: Any]

        let delta: (input: Int, cached: Int, output: Int)
        if let last {
            delta = (intval(last["input_tokens"]), intval(last["cached_input_tokens"]), intval(last["output_tokens"]))
        } else if let total {
            let totalTuple = (intval(total["input_tokens"]), intval(total["cached_input_tokens"]), intval(total["output_tokens"]))
            if let baseline = runningBaseline {
                delta = (
                    max(0, totalTuple.0 - baseline.input),
                    max(0, totalTuple.1 - baseline.cached),
                    max(0, totalTuple.2 - baseline.output)
                )
            } else {
                delta = totalTuple
            }
        } else {
            return
        }

        if let total {
            runningBaseline = (intval(total["input_tokens"]), intval(total["cached_input_tokens"]), intval(total["output_tokens"]))
        }

        if delta.input == 0, delta.cached == 0, delta.output == 0 { return }

        let rawModel = currentModel ?? "gpt-5"
        let normalizedModel = CostPricing.normalizeOpenAIModel(rawModel)
        let cached = min(delta.cached, delta.input)
        let mappedInput = delta.input - cached
        let mappedCacheRead = cached
        let mappedOutput = delta.output

        let dedupKey = "\(ts)|\(normalizedModel)|\(delta.input)|\(delta.cached)|\(delta.output)"
        if !seen.insert(dedupKey).inserted { return }

        let pricingResult = pricing.pricing(model: rawModel, on: date)
        let cost = pricingResult.map {
            CostPricing.claudeCostUSD(model: rawModel, input: mappedInput, cacheRead: mappedCacheRead,
                cacheCreation: 0, cacheCreation1h: 0, output: mappedOutput, pricing: $0)
        } ?? nil
        let nanos = cost.map { Int(($0 * 1_000_000_000).rounded()) } ?? 0

        var dayModels = buckets[dayKey] ?? [:]
        dayModels[normalizedModel] = (dayModels[normalizedModel] ?? ModelTokenTotals()) + ModelTokenTotals(
            input: mappedInput, cacheRead: mappedCacheRead, cacheCreation: 0, cacheCreation1h: 0,
            output: mappedOutput, costNanos: nanos, requestCount: 1, pricedCount: cost == nil ? 0 : 1)
        buckets[dayKey] = dayModels
    }

    nonisolated private func intval(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

    nonisolated private func parseTimestamp(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}

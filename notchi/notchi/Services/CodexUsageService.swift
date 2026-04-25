import Foundation

nonisolated struct CodexUsageSnapshot: Sendable, Equatable {
    let usage: QuotaPeriod
    let observedAt: Date
}

nonisolated struct CodexUsageServiceDependencies: Sendable {
    var resolveUsage: @Sendable ([String]) -> CodexUsageSnapshot?
    var now: @Sendable () -> Date

    static let live = CodexUsageServiceDependencies(
        resolveUsage: { transcriptPaths in
            CodexUsageSnapshotResolver.latestSnapshot(transcriptPaths: transcriptPaths)
        },
        now: { Date() }
    )
}

@MainActor
@Observable
final class CodexUsageService {
    static let shared = CodexUsageService()

    var currentUsage: QuotaPeriod?
    var isUsageStale = false
    var statusMessage: String?
    var lastObservedAt: Date?

    private static let staleObservationInterval: TimeInterval = 120

    private let dependencies: CodexUsageServiceDependencies

    init(dependencies: CodexUsageServiceDependencies = .live) {
        self.dependencies = dependencies
    }

    func refresh(transcriptPaths: [String]) async {
        let paths = Array(Set(transcriptPaths)).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !paths.isEmpty else {
            clear()
            return
        }

        let resolver = dependencies.resolveUsage
        let snapshot = await Task.detached(priority: .utility) {
            resolver(paths)
        }.value

        apply(snapshot)
    }

    func clear() {
        currentUsage = nil
        isUsageStale = false
        statusMessage = nil
        lastObservedAt = nil
    }

    private func apply(_ snapshot: CodexUsageSnapshot?) {
        let now = dependencies.now()

        if let snapshot, isUsageStillValid(snapshot.usage, now: now) {
            currentUsage = snapshot.usage
            lastObservedAt = snapshot.observedAt
            isUsageStale = now.timeIntervalSince(snapshot.observedAt) > Self.staleObservationInterval
            statusMessage = nil
            return
        }

        guard isUsageStillValid(currentUsage, now: now) else {
            clear()
            return
        }

        isUsageStale = true
        statusMessage = nil
    }

    private func isUsageStillValid(_ usage: QuotaPeriod?, now: Date) -> Bool {
        guard let usage, let resetDate = usage.resetDate else {
            return false
        }
        return resetDate > now
    }
}

nonisolated enum CodexUsageSnapshotResolver {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoBasic = ISO8601DateFormatter()

    static func latestSnapshot(transcriptPaths: [String]) -> CodexUsageSnapshot? {
        transcriptPaths
            .compactMap { latestSnapshot(transcriptPath: $0) }
            .max { lhs, rhs in lhs.observedAt < rhs.observedAt }
    }

    static func latestSnapshot(transcriptPath: String) -> CodexUsageSnapshot? {
        let trimmedPath = transcriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty,
              let contents = try? String(contentsOfFile: trimmedPath, encoding: .utf8) else {
            return nil
        }

        var latestSnapshot: CodexUsageSnapshot?
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(#""token_count""#),
                  let data = String(line).data(using: .utf8),
                  let event = try? JSONDecoder().decode(CodexTokenCountEvent.self, from: data),
                  event.payload?.type == "token_count",
                  let primary = event.payload?.rateLimits?.primary,
                  let observedAt = parseDate(event.timestamp) else {
                continue
            }

            let snapshot = CodexUsageSnapshot(
                usage: QuotaPeriod(
                    utilization: primary.usedPercent.rounded(),
                    resetDate: Date(timeIntervalSince1970: primary.resetsAt)
                ),
                observedAt: observedAt
            )
            if latestSnapshot.map({ observedAt > $0.observedAt }) ?? true {
                latestSnapshot = snapshot
            }
        }

        return latestSnapshot
    }

    private static func parseDate(_ rawValue: String?) -> Date? {
        guard let rawValue else { return nil }
        return isoFractional.date(from: rawValue) ?? isoBasic.date(from: rawValue)
    }
}

private nonisolated struct CodexTokenCountEvent: Decodable {
    let timestamp: String?
    let payload: Payload?

    struct Payload: Decodable {
        let type: String
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
        }
    }

    struct RateLimits: Decodable {
        let primary: Limit?
    }

    struct Limit: Decodable {
        let usedPercent: Double
        let resetsAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetsAt = "resets_at"
        }
    }
}

import XCTest
@testable import notchi

@MainActor
final class CodexUsageServiceTests: XCTestCase {
    func testResolverDecodesSecondaryRateLimitAsWeeklyUsage() throws {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: rolloutURL) }

        let contents = """
        {"timestamp":"2026-04-25T07:03:14.886Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":11.0,"window_minutes":300,"resets_at":1777103326},"secondary":{"used_percent":27.0,"window_minutes":10080,"resets_at":1777621726}}}}
        """
        try contents.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = try XCTUnwrap(CodexUsageSnapshotResolver.latestSnapshot(transcriptPath: rolloutURL.path))

        XCTAssertEqual(snapshot.usage?.usagePercentage, 11)
        XCTAssertEqual(snapshot.weeklyUsage?.usagePercentage, 27)
        let weeklyReset = try XCTUnwrap(snapshot.weeklyUsage?.resetDate)
        XCTAssertEqual(weeklyReset.timeIntervalSince1970, 1_777_621_726, accuracy: 0.001)
    }

    func testResolverTreatsWeeklyWindowInPrimarySlotAsWeeklyUsage() throws {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: rolloutURL) }

        let contents = """
        {"timestamp":"2026-04-25T07:03:14.886Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":22.0,"window_minutes":10080,"resets_at":1777621726},"secondary":null}}}
        """
        try contents.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = try XCTUnwrap(CodexUsageSnapshotResolver.latestSnapshot(transcriptPath: rolloutURL.path))

        XCTAssertNil(snapshot.usage)
        XCTAssertEqual(snapshot.weeklyUsage?.usagePercentage, 22)
        let weeklyReset = try XCTUnwrap(snapshot.weeklyUsage?.resetDate)
        XCTAssertEqual(weeklyReset.timeIntervalSince1970, 1_777_621_726, accuracy: 0.001)
    }

    func testResolverTreatsSoonerResetAsSessionWhenBothWindowsLackSize() throws {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: rolloutURL) }

        let contents = """
        {"timestamp":"2026-04-25T07:03:14.886Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":27.0,"resets_at":1777621726},"secondary":{"used_percent":11.0,"resets_at":1777103326}}}}
        """
        try contents.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = try XCTUnwrap(CodexUsageSnapshotResolver.latestSnapshot(transcriptPath: rolloutURL.path))

        XCTAssertEqual(snapshot.usage?.usagePercentage, 11)
        XCTAssertEqual(snapshot.weeklyUsage?.usagePercentage, 27)
    }

    func testResolverTreatsLoneUnsizedWindowAsWeekly() throws {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: rolloutURL) }

        let contents = """
        {"timestamp":"2026-04-25T07:03:14.886Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":22.0,"resets_at":1777621726}}}}
        """
        try contents.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = try XCTUnwrap(CodexUsageSnapshotResolver.latestSnapshot(transcriptPath: rolloutURL.path))

        XCTAssertNil(snapshot.usage)
        XCTAssertEqual(snapshot.weeklyUsage?.usagePercentage, 22)
    }

    func testRefreshPublishesWeeklyOnlySnapshot() async {
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            resolveUsage: { _ in
                CodexUsageSnapshot(
                    usage: nil,
                    weeklyUsage: QuotaPeriod(utilization: 22, resetDate: Date(timeIntervalSince1970: 2_000)),
                    observedAt: Date(timeIntervalSince1970: 1_000)
                )
            },
            now: { Date(timeIntervalSince1970: 1_010) }
        ))

        await service.refresh(transcriptPaths: ["/tmp/rollout.jsonl"])

        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.currentWeeklyUsage?.usagePercentage, 22)
        XCTAssertTrue(service.hasUsageData)
    }

    func testResolverLeavesWeeklyUsageNilWhenSecondaryMissing() throws {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: rolloutURL) }

        let contents = """
        {"timestamp":"2026-04-25T07:03:14.886Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":11.0,"window_minutes":300,"resets_at":1777103326}}}}
        """
        try contents.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = try XCTUnwrap(CodexUsageSnapshotResolver.latestSnapshot(transcriptPath: rolloutURL.path))

        XCTAssertNil(snapshot.weeklyUsage)
    }

    func testResolverReadsLatestTokenCountFromRollout() throws {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: rolloutURL) }

        let contents = """
        {"timestamp":"2026-04-25T07:03:14.886Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":11.0,"window_minutes":300,"resets_at":1777103326}}}}
        {"timestamp":"2026-04-25T07:01:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":7.4,"window_minutes":300,"resets_at":1777103326}}}}
        """
        try contents.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = try XCTUnwrap(CodexUsageSnapshotResolver.latestSnapshot(transcriptPath: rolloutURL.path))

        XCTAssertEqual(snapshot.usage?.usagePercentage, 11)
        XCTAssertEqual(snapshot.observedAt.timeIntervalSince1970, 1_777_100_594.886, accuracy: 0.001)
    }

    func testResolverIgnoresNonTokenCountEventsInRollout() throws {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-mixed-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: rolloutURL) }

        let contents = """
        {"timestamp":"2026-04-25T07:00:00.000Z","type":"event_msg","payload":{"type":"message","role":"assistant","content":"hello"}}
        {"timestamp":"2026-04-25T07:03:14.886Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":15.0,"window_minutes":300,"resets_at":1777103326}}}}
        {"timestamp":"2026-04-25T07:04:00.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}}
        """
        try contents.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = try XCTUnwrap(CodexUsageSnapshotResolver.latestSnapshot(transcriptPath: rolloutURL.path))

        XCTAssertEqual(snapshot.usage?.usagePercentage, 15)
    }

    func testResolverFindsLatestTokenCountInTailOfRolloutLargerThanWindow() throws {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-large-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: rolloutURL) }

        let oldTokenCount = #"{"timestamp":"2026-04-25T07:01:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":7.4,"window_minutes":300,"resets_at":1777103326}}}}"#
        let padding = #"{"type":"event_msg","payload":{"type":"message","content":""# +
            String(repeating: "x", count: 2_048) + #""}}"#
        let latestTokenCount = #"{"timestamp":"2026-04-25T07:03:14.886Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42.0,"window_minutes":300,"resets_at":1777103326}}}}"#
        let contents = [oldTokenCount, padding, latestTokenCount].joined(separator: "\n")
        try contents.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let snapshot = try XCTUnwrap(CodexUsageSnapshotResolver.latestSnapshot(
            transcriptPath: rolloutURL.path,
            maxTailBytes: 512
        ))

        XCTAssertEqual(snapshot.usage?.usagePercentage, 42)
    }

    func testResolverKeepsTokenCountWhenTailWindowStartsOnLineBoundary() throws {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-boundary-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: rolloutURL) }

        let prefix = #"{"type":"event_msg","payload":{"type":"message","content":"x"}}"#
        let tokenCount = #"{"timestamp":"2026-04-25T07:03:14.886Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42.0,"window_minutes":300,"resets_at":1777103326}}}}"#
        let contents = prefix + "\n" + tokenCount + "\n"
        try contents.write(to: rolloutURL, atomically: true, encoding: .utf8)

        // Size the window so it begins exactly at the token-count line's first byte,
        // i.e. immediately after the prefix line's newline.
        let tokenCountStart = (prefix + "\n").utf8.count
        let maxTailBytes = Data(contents.utf8).count - tokenCountStart

        let snapshot = try XCTUnwrap(CodexUsageSnapshotResolver.latestSnapshot(
            transcriptPath: rolloutURL.path,
            maxTailBytes: maxTailBytes
        ))

        XCTAssertEqual(snapshot.usage?.usagePercentage, 42)
    }

    func testResolverIgnoresTokenCountOutsideTailWindow() throws {
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-head-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: rolloutURL) }

        let tokenCount = #"{"timestamp":"2026-04-25T07:01:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":7.4,"window_minutes":300,"resets_at":1777103326}}}}"#
        let padding = #"{"type":"event_msg","payload":{"type":"message","content":""# +
            String(repeating: "x", count: 2_048) + #""}}"#
        let contents = [tokenCount, padding].joined(separator: "\n")
        try contents.write(to: rolloutURL, atomically: true, encoding: .utf8)

        XCTAssertNil(CodexUsageSnapshotResolver.latestSnapshot(
            transcriptPath: rolloutURL.path,
            maxTailBytes: 256
        ))
    }

    func testRefreshMarksOldButUnexpiredUsageAsStaleWithoutStatusMessage() async {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_930)
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            resolveUsage: { _ in
                CodexUsageSnapshot(
                    usage: QuotaPeriod(utilization: 11, resetDate: Date(timeIntervalSince1970: 2_000)),
                    weeklyUsage: nil,
                    observedAt: observedAt
                )
            },
            now: { now }
        ))

        await service.refresh(transcriptPaths: ["/tmp/rollout.jsonl"])

        XCTAssertEqual(service.currentUsage?.usagePercentage, 11)
        XCTAssertTrue(service.isUsageStale)
        XCTAssertNil(service.statusMessage)
        XCTAssertEqual(service.lastObservedAt, observedAt)
    }

    func testRefreshClearsExpiredUsage() async {
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            resolveUsage: { _ in
                CodexUsageSnapshot(
                    usage: QuotaPeriod(utilization: 11, resetDate: Date(timeIntervalSince1970: 900)),
                    weeklyUsage: nil,
                    observedAt: Date(timeIntervalSince1970: 800)
                )
            },
            now: { Date(timeIntervalSince1970: 1_000) }
        ))

        await service.refresh(transcriptPaths: ["/tmp/rollout.jsonl"])

        XCTAssertNil(service.currentUsage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertNil(service.statusMessage)
        XCTAssertNil(service.lastObservedAt)
    }
}

import XCTest
@testable import notchi

@MainActor
final class CodexUsageServiceTests: XCTestCase {
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

        XCTAssertEqual(snapshot.usage.usagePercentage, 11)
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

        XCTAssertEqual(snapshot.usage.usagePercentage, 15)
    }

    func testRefreshMarksOldButUnexpiredUsageAsStaleWithoutStatusMessage() async {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_130)
        let service = CodexUsageService(dependencies: CodexUsageServiceDependencies(
            resolveUsage: { _ in
                CodexUsageSnapshot(
                    usage: QuotaPeriod(utilization: 11, resetDate: Date(timeIntervalSince1970: 2_000)),
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

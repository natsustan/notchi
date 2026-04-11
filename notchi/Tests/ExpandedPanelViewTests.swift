import XCTest
@testable import notchi

@MainActor
final class ExpandedPanelViewTests: XCTestCase {
    func testSharedUsageBarStaysVisibleWhenCodexSessionIsSelectedAndClaudeIsAlsoActive() {
        let claude = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let codex = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertTrue(
            ExpandedPanelView.shouldShowSharedUsageBar(
                effectiveSession: codex,
                activeSessions: [codex, claude]
            )
        )
    }

    func testSharedUsageBarHidesWhenOnlyCodexSessionsAreActive() {
        let codex = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertFalse(
            ExpandedPanelView.shouldShowSharedUsageBar(
                effectiveSession: codex,
                activeSessions: [codex]
            )
        )
    }

    func testSharedUsageBarStaysVisibleWhenNoEffectiveSessionExistsYet() {
        XCTAssertTrue(
            ExpandedPanelView.shouldShowSharedUsageBar(
                effectiveSession: nil,
                activeSessions: []
            )
        )
    }
}

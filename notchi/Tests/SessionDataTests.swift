import CoreGraphics
import XCTest
@testable import notchi

@MainActor
final class SessionDataTests: XCTestCase {
    func testResolveXPositionReturnsCandidateWithinConfiguredRange() {
        let positions = stride(from: 0.05, through: 0.95, by: 0.15).map { CGFloat($0) }

        let resolved = SessionData.resolveXPositionForTesting(
            hash: 0,
            existingPositions: positions
        )

        XCTAssertGreaterThanOrEqual(resolved, CGFloat(0.05))
        XCTAssertLessThanOrEqual(resolved, CGFloat(0.95))
    }

    func testResolveXPositionFallsBackToMostSeparatedCandidateWhenAllCandidatesOverlap() {
        let positions = stride(from: 0.05, through: 0.95, by: 0.15).map { CGFloat($0) }

        let resolved = SessionData.resolveXPositionForTesting(
            hash: 0,
            existingPositions: positions
        )

        XCTAssertEqual(resolved, CGFloat(0.28), accuracy: 0.0001)
    }

    func testSpinnerVerbOnlyAdvancesWhenReplyCycleAdvances() {
        let session = SessionData(sessionId: "session-1", cwd: "/tmp/project")
        let initialVerb = session.currentSpinnerVerb

        session.recordPreToolUse(tool: "Read", toolInput: ["file_path": "README.md"], toolUseId: "tool-1")
        session.recordPostToolUse(tool: "Read", toolUseId: "tool-1", success: true)

        XCTAssertEqual(session.currentSpinnerVerb, initialVerb)

        session.advanceSpinnerVerbForReply()

        XCTAssertNotEqual(session.currentSpinnerVerb, initialVerb)
        XCTAssertTrue(SpinnerVerbs.all.contains(session.currentSpinnerVerb))
    }

    func testSessionStartsWithProviderSpecificSpinnerVerb() {
        let claude = SessionData(sessionId: "claude-session", provider: .claude, cwd: "/tmp/project")
        let codex = SessionData(sessionId: "codex-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertEqual(claude.currentSpinnerVerb, "Clauding")
        XCTAssertEqual(codex.currentSpinnerVerb, "Codexing")
    }

    func testStableIdentifierIncludesProviderWhenRawSessionIdMatches() {
        let claude = SessionData(sessionId: "shared-session", provider: .claude, cwd: "/tmp/project")
        let codex = SessionData(sessionId: "shared-session", provider: .codex, cwd: "/tmp/project")

        XCTAssertNotEqual(claude.id, codex.id)
        XCTAssertEqual(claude.id, "claude:shared-session")
        XCTAssertEqual(codex.id, "codex:shared-session")
    }
}

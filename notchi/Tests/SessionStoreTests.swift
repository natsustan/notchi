import XCTest
@testable import notchi

@MainActor
final class SessionStoreTests: XCTestCase {
    override func tearDown() async throws {
        let sessionIds = Array(SessionStore.shared.sessions.keys)
        sessionIds.forEach { SessionStore.shared.dismissSession($0) }
        try await super.tearDown()
    }

    func testUserPromptSubmitClearsPreviousTurnToolEventsAndAssistantMessages() {
        let sessionId = "turn-reset-\(UUID().uuidString)"
        let store = SessionStore.shared

        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "first"
        ))

        _ = store.process(makeEvent(
            sessionId: sessionId,
            event: .preToolUse,
            status: "processing",
            tool: "Read",
            toolUseId: "tool-1"
        ))
        session.recordAssistantMessages([
            AssistantMessage(id: UUID().uuidString, text: "Old reply", timestamp: Date())
        ])

        XCTAssertEqual(session.recentEvents.count, 1)
        XCTAssertEqual(session.recentAssistantMessages.count, 1)

        _ = store.process(makeEvent(
            sessionId: sessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "second"
        ))

        XCTAssertTrue(session.recentEvents.isEmpty)
        XCTAssertTrue(session.recentAssistantMessages.isEmpty)
        XCTAssertEqual(session.lastUserPrompt, "second")
    }

    func testDisplaySessionNumbersRenumberAfterDismissal() {
        let store = SessionStore.shared
        let cwd = "/tmp/notchi"

        let first = store.process(makeEvent(
            sessionId: "renumber-1-\(UUID().uuidString)",
            cwd: cwd,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "one"
        ))
        let second = store.process(makeEvent(
            sessionId: "renumber-2-\(UUID().uuidString)",
            cwd: cwd,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "two"
        ))
        let third = store.process(makeEvent(
            sessionId: "renumber-3-\(UUID().uuidString)",
            cwd: cwd,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "three"
        ))

        XCTAssertEqual(store.displaySessionNumber(for: first), 1)
        XCTAssertEqual(store.displaySessionNumber(for: second), 2)
        XCTAssertEqual(store.displaySessionNumber(for: third), 3)

        store.dismissSession(first.id)
        store.dismissSession(second.id)

        XCTAssertEqual(store.displaySessionNumber(for: third), 1)
        XCTAssertEqual(store.displaySessionLabel(for: third), "notchi #1")
        XCTAssertEqual(store.displayTitle(for: third), "notchi #1 - three")
    }

    func testMixedProvidersShareProjectNumberingAndAvoidIdentityCollisions() {
        let store = SessionStore.shared
        let cwd = "/tmp/notchi"

        let claude = store.process(makeEvent(
            sessionId: "shared-session",
            provider: .claude,
            cwd: cwd,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "claude"
        ))
        let codex = store.process(makeEvent(
            sessionId: "shared-session",
            provider: .codex,
            cwd: cwd,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "codex"
        ))

        XCTAssertNotEqual(claude.id, codex.id)
        XCTAssertEqual(store.displaySessionNumber(for: claude), 1)
        XCTAssertEqual(store.displaySessionNumber(for: codex), 2)
        XCTAssertEqual(store.displaySessionLabel(for: claude), "notchi #1")
        XCTAssertEqual(store.displaySessionLabel(for: codex), "notchi #2")
    }

    private func makeEvent(
        sessionId: String,
        provider: AgentProvider = .claude,
        cwd: String = "/tmp",
        event: NormalizedAgentEvent,
        status: String,
        userPrompt: String? = nil,
        tool: String? = nil,
        toolUseId: String? = nil
    ) -> HookEvent {
        HookEvent(
            provider: provider,
            rawSessionId: sessionId,
            transcriptPath: nil,
            cwd: cwd,
            event: event,
            status: status,
            pid: nil,
            tty: nil,
            tool: tool,
            toolInput: nil,
            toolUseId: toolUseId,
            userPrompt: userPrompt,
            permissionMode: nil,
            interactive: true
        )
    }
}

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
            event: "UserPromptSubmit",
            status: "processing",
            userPrompt: "first"
        ))

        _ = store.process(makeEvent(
            sessionId: sessionId,
            event: "PreToolUse",
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
            event: "UserPromptSubmit",
            status: "processing",
            userPrompt: "second"
        ))

        XCTAssertTrue(session.recentEvents.isEmpty)
        XCTAssertTrue(session.recentAssistantMessages.isEmpty)
        XCTAssertEqual(session.lastUserPrompt, "second")
    }

    private func makeEvent(
        sessionId: String,
        event: String,
        status: String,
        userPrompt: String? = nil,
        tool: String? = nil,
        toolUseId: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp",
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

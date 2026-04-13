import Foundation
import XCTest
@testable import notchi

@MainActor
final class NotchiStateMachineTests: XCTestCase {
    override func tearDown() async throws {
        let sessionKeys = Array(SessionStore.shared.sessions.keys)
        sessionKeys.forEach { SessionStore.shared.dismissSession($0) }
        NotchiStateMachine.shared.resetTestingHooks()
        try await super.tearDown()
    }

    func testAssistantMessagesWakeIdleAndSleepingInteractiveSessionsWithActiveWatcher() {
        let stateMachine = NotchiStateMachine.shared
        let result = ParseResult(messages: [makeAssistantMessage()], interrupted: false)

        for initialTask in [NotchiTask.idle, .sleeping] {
            let sessionId = "wake-\(initialTask.rawValue)-\(UUID().uuidString)"
            let session = makeInteractiveSession(sessionId: sessionId)
            session.updateTask(initialTask)
            session.updateProcessingState(isProcessing: false)

            stateMachine.reconcileFileSyncResult(result, for: session.sessionKey, hasActiveWatcher: true)

            XCTAssertEqual(session.task, .working)
            XCTAssertTrue(session.isProcessing)

            SessionStore.shared.dismissSession(session.sessionKey)
        }
    }

    func testAssistantMessagesDoNotWakeIdleSessionAfterStopWithoutWatcher() {
        let stateMachine = NotchiStateMachine.shared
        let sessionId = "stop-\(UUID().uuidString)"
        let session = makeInteractiveSession(sessionId: sessionId)

        _ = SessionStore.shared.process(makeEvent(sessionId: sessionId, event: .stop, status: "waiting_for_input"))
        XCTAssertEqual(session.task, .idle)
        XCTAssertFalse(session.isProcessing)

        let result = ParseResult(messages: [makeAssistantMessage()], interrupted: false)
        SessionStore.shared.recordAssistantMessages(result.messages, for: session.sessionKey)
        stateMachine.reconcileFileSyncResult(result, for: session.sessionKey, hasActiveWatcher: false)

        XCTAssertEqual(session.task, .idle)
        XCTAssertFalse(session.isProcessing)
    }

    func testSessionStartForwardsToClaudeUsageHandler() {
        let stateMachine = NotchiStateMachine.shared
        var receivedTriggers: [ClaudeUsageResumeTrigger] = []
        stateMachine.handleClaudeUsageResumeTrigger = { trigger in
            receivedTriggers.append(trigger)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: "session-start-\(UUID().uuidString)",
            event: .sessionStarted,
            status: "processing"
        ))

        XCTAssertEqual(receivedTriggers, [.sessionStart])
    }

    func testInteractiveUserPromptSubmitForwardsToClaudeUsageHandler() {
        let stateMachine = NotchiStateMachine.shared
        var receivedTriggers: [ClaudeUsageResumeTrigger] = []
        stateMachine.handleClaudeUsageResumeTrigger = { trigger in
            receivedTriggers.append(trigger)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: "prompt-submit-\(UUID().uuidString)",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        XCTAssertEqual(receivedTriggers, [.userPromptSubmit])
    }

    func testLocalSlashUserPromptSubmitDoesNotForwardToClaudeUsageHandler() {
        let stateMachine = NotchiStateMachine.shared
        var receivedTriggers: [ClaudeUsageResumeTrigger] = []
        stateMachine.handleClaudeUsageResumeTrigger = { trigger in
            receivedTriggers.append(trigger)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: "local-prompt-\(UUID().uuidString)",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "/help"
        ))

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    func testNonInteractiveUserPromptSubmitDoesNotForwardToClaudeUsageHandler() {
        let stateMachine = NotchiStateMachine.shared
        var receivedTriggers: [ClaudeUsageResumeTrigger] = []
        stateMachine.handleClaudeUsageResumeTrigger = { trigger in
            receivedTriggers.append(trigger)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: "noninteractive-prompt-\(UUID().uuidString)",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello",
            interactive: false
        ))

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    func testAgentHookEnvelopeAllowsMissingTranscriptPathForStaleHooks() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": "stale-hook",
            "cwd": "/tmp",
            "event": "SessionStart",
            "status": "waiting_for_input",
        ])

        let event = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        XCTAssertNil(event.transcriptPath)
        XCTAssertEqual(event.sessionId, "stale-hook")
        XCTAssertEqual(event.provider, .claude)
    }

    func testCodexPromptSubmitDoesNotForwardToClaudeUsageHandler() {
        let stateMachine = NotchiStateMachine.shared
        var receivedTriggers: [ClaudeUsageResumeTrigger] = []
        stateMachine.handleClaudeUsageResumeTrigger = { trigger in
            receivedTriggers.append(trigger)
        }

        stateMachine.handleEvent(makeEvent(
            sessionId: "codex-prompt-\(UUID().uuidString)",
            provider: .codex,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        XCTAssertTrue(receivedTriggers.isEmpty)
    }

    func testCodexSessionStartDoesNotCreateVisibleSession() {
        let stateMachine = NotchiStateMachine.shared
        let sessionId = "codex-start-\(UUID().uuidString)"

        // Intentionally omit transcriptPath so this covers the blank-session
        // case without starting a watcher as a side effect.
        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            event: .sessionStarted,
            status: "processing"
        ))

        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: sessionId)
        XCTAssertNil(SessionStore.shared.session(for: sessionKey))
        XCTAssertEqual(SessionStore.shared.activeSessionCount, 0)
    }

    func testCodexVisibleSessionPreservesOriginalSessionStartTime() async throws {
        let stateMachine = NotchiStateMachine.shared
        let sessionId = "codex-visible-start-\(UUID().uuidString)"
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: sessionId)

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            event: .sessionStarted,
            status: "processing"
        ))

        try await Task.sleep(nanoseconds: 200_000_000)

        stateMachine.handleEvent(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        guard let session = SessionStore.shared.session(for: sessionKey),
              let promptSubmitTime = session.promptSubmitTime else {
            return XCTFail("Expected visible Codex session after first real event")
        }

        XCTAssertGreaterThanOrEqual(promptSubmitTime.timeIntervalSince(session.sessionStartTime), 0.15)
    }

    func testApplyingParsedCodexSessionEventsRecordsBashActivity() {
        let stateMachine = NotchiStateMachine.shared
        let session = SessionStore.shared.process(makeEvent(
            sessionId: "codex-events-\(UUID().uuidString)",
            provider: .codex,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        stateMachine.applyParsedSessionEvents([
            ParsedSessionEvent(
                id: "tool-start",
                event: .preToolUse,
                status: "running_tool",
                tool: "Bash",
                toolInput: ["command": AnyCodable("pwd")],
                toolUseId: "call-123"
            ),
            ParsedSessionEvent(
                id: "tool-end",
                event: .postToolUse,
                status: "processing",
                tool: "Bash",
                toolInput: nil,
                toolUseId: "call-123"
            ),
        ], for: session.sessionKey)

        XCTAssertEqual(session.recentEvents.count, 1)
        XCTAssertEqual(session.recentEvents.first?.tool, "Bash")
        XCTAssertEqual(session.recentEvents.first?.description, "pwd")
        XCTAssertEqual(session.recentEvents.first?.status, .success)
    }

    private func makeInteractiveSession(sessionId: String) -> SessionData {
        SessionStore.shared.process(makeEvent(
            sessionId: sessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))
    }

    private func makeAssistantMessage() -> AssistantMessage {
        AssistantMessage(id: UUID().uuidString, text: "Still working", timestamp: Date())
    }

    private func makeEvent(
        sessionId: String,
        provider: AgentProvider = .claude,
        event: NormalizedAgentEvent,
        status: String,
        userPrompt: String? = nil,
        interactive: Bool = true
    ) -> HookEvent {
        HookEvent(
            provider: provider,
            rawSessionId: sessionId,
            transcriptPath: nil,
            cwd: "/tmp",
            event: event,
            status: status,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            userPrompt: userPrompt,
            permissionMode: nil,
            interactive: interactive
        )
    }
}

import XCTest
@testable import notchi

@MainActor
final class SessionStoreTests: XCTestCase {
    override func tearDown() async throws {
        let sessionKeys = Array(SessionStore.shared.sessions.keys)
        sessionKeys.forEach { SessionStore.shared.dismissSession($0) }
        SessionStore.shared.resetTestingHooks()
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
        XCTAssertFalse(session.lastUserPromptHasAttachments)
    }

    func testUserPromptSubmitTracksAttachmentStateSeparatelyFromPromptText() {
        let sessionId = "attached-prompt-\(UUID().uuidString)"
        let store = SessionStore.shared

        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "testing",
            userPromptHasAttachments: true
        ))

        XCTAssertEqual(session.lastUserPrompt, "testing")
        XCTAssertTrue(session.lastUserPromptHasAttachments)

        _ = store.process(makeEvent(
            sessionId: sessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "plain",
            userPromptHasAttachments: false
        ))

        XCTAssertEqual(session.lastUserPrompt, "plain")
        XCTAssertFalse(session.lastUserPromptHasAttachments)
    }

    func testAttachmentOnlyUserPromptStillRecordsPromptSubmission() {
        let store = SessionStore.shared

        let session = store.process(makeEvent(
            sessionId: "attachment-only-\(UUID().uuidString)",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: nil,
            userPromptHasAttachments: true
        ))

        XCTAssertNil(session.lastUserPrompt)
        XCTAssertTrue(session.lastUserPromptHasAttachments)
        XCTAssertNotNil(session.promptSubmitTime)
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

        store.dismissSession(first.sessionKey)
        store.dismissSession(second.sessionKey)

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
        XCTAssertNotNil(store.sessions[claude.sessionKey])
        XCTAssertNotNil(store.sessions[codex.sessionKey])
    }

    func testCodexDisplayTitlePrefersCodexThreadTitle() {
        let store = SessionStore.shared
        store.setCodexMetadataResolverForTesting { transcriptPath in
            transcriptPath == "/tmp/rollout.jsonl"
                ? CodexThreadMetadata(title: "Review uncommitted changes", archived: false)
                : nil
        }

        let session = store.process(makeEvent(
            sessionId: "codex-title-\(UUID().uuidString)",
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: "/tmp/rollout.jsonl",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "raw prompt"
        ))

        XCTAssertEqual(session.codexTranscriptPath, "/tmp/rollout.jsonl")
        XCTAssertFalse(session.codexArchived)
        XCTAssertNil(session.codexTitle)

        _ = store.refreshCodexThreadMetadataForTesting()

        XCTAssertEqual(session.codexTitle, "Review uncommitted changes")
        XCTAssertEqual(store.displayTitle(for: session), "notchi #1 - Review uncommitted changes")
    }

    func testRefreshCodexThreadMetadataReturnsArchivedSessionsAndUpdatesTitle() {
        let store = SessionStore.shared
        let transcriptPath = "/tmp/archived-rollout.jsonl"
        store.setCodexMetadataResolverForTesting { _ in
            CodexThreadMetadata(title: "Initial title", archived: false)
        }

        let session = store.process(makeEvent(
            sessionId: "codex-archived-title-\(UUID().uuidString)",
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "raw prompt"
        ))

        store.setCodexMetadataResolverForTesting { path in
            path == transcriptPath
                ? CodexThreadMetadata(title: "Archived title", archived: true)
                : nil
        }

        let archivedSessions = store.refreshCodexThreadMetadataForTesting()

        XCTAssertEqual(archivedSessions.map(\.sessionKey), [session.sessionKey])
        XCTAssertEqual(session.codexTitle, "Archived title")
        XCTAssertTrue(session.codexArchived)
    }

    func testCodexThreadMetadataResolverMatchesLiteralRolloutPathFromSQLiteOutput() {
        let separator = "\u{1F}"
        let transcriptPath = "/tmp/notchi'; DROP TABLE threads; --/rollout.jsonl"
        let output = [
            ["other", "/tmp/other.jsonl", "4F74686572", "0"].joined(separator: separator),
            ["thread-1", transcriptPath, "526576696577", "0"].joined(separator: separator),
        ].joined(separator: "\n")

        let metadata = CodexThreadMetadataResolver.metadata(
            fromSQLiteOutput: output,
            matchingTranscriptPath: transcriptPath
        )

        XCTAssertEqual(metadata, CodexThreadMetadata(title: "Review", archived: false))
    }

    func testCodexThreadMetadataResolverFallsBackToThreadIdFromTranscriptFilename() {
        let separator = "\u{1F}"
        let threadId = "123e4567-e89b-12d3-a456-426614174000"
        let transcriptPath = "/tmp/rollout-\(threadId).jsonl"
        let output = [
            threadId,
            "/tmp/renamed-rollout.jsonl",
            "4172636869766564",
            "1",
        ].joined(separator: separator)

        let metadata = CodexThreadMetadataResolver.metadata(
            fromSQLiteOutput: output,
            matchingTranscriptPath: transcriptPath
        )

        XCTAssertEqual(metadata, CodexThreadMetadata(title: "Archived", archived: true))
    }

    private func makeEvent(
        sessionId: String,
        provider: AgentProvider = .claude,
        cwd: String = "/tmp",
        transcriptPath: String? = nil,
        event: NormalizedAgentEvent,
        status: String,
        userPrompt: String? = nil,
        userPromptHasAttachments: Bool = false,
        tool: String? = nil,
        toolUseId: String? = nil
    ) -> HookEvent {
        HookEvent(
            provider: provider,
            rawSessionId: sessionId,
            transcriptPath: transcriptPath,
            cwd: cwd,
            event: event,
            status: status,
            tool: tool,
            toolInput: nil,
            toolUseId: toolUseId,
            userPrompt: userPrompt,
            userPromptHasAttachments: userPromptHasAttachments,
            permissionMode: nil,
            interactive: true
        )
    }
}

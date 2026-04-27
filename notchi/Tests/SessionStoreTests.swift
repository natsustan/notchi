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

    func testCodexCompactionSignalResolverParsesLatestTokenLimitLogRow() {
        let separator = "\u{1F}"
        let threadId = "11111111-1111-1111-1111-111111111111"
        let timestamp: TimeInterval = 1_775_000_000
        let nanoseconds = 250_000_000
        let body = """
        session_loop{thread_id=thread}:turn:run_turn: post sampling token usage turn_id=turn total_usage_tokens=256300 estimated_token_count=Some(177642) auto_compact_limit=244800 token_limit_reached=true model_needs_follow_up=true has_pending_input=false needs_follow_up=true
        """
        let output = "\(threadId)\(separator)\(Int(timestamp))\(separator)\(nanoseconds)\(separator)\(body)"

        let signal = CodexCompactionSignalResolver.latestSignals(fromSQLiteOutput: output)[threadId]

        XCTAssertEqual(signal?.observedAt, Date(timeIntervalSince1970: timestamp + 0.25))
        XCTAssertEqual(signal?.totalUsageTokens, 256300)
        XCTAssertEqual(signal?.estimatedTokenCount, 177642)
        XCTAssertEqual(signal?.autoCompactLimit, 244800)
        XCTAssertEqual(signal?.tokenLimitReached, true)
    }

    func testCodexCompactionSignalResolverDoesNotMatchPrefixedFields() {
        let separator = "\u{1F}"
        let threadId = "11111111-1111-1111-1111-111111111111"
        let timestamp: TimeInterval = 1_775_000_000
        let body = """
        session_loop{thread_id=thread}:turn:run_turn: post sampling token usage turn_id=turn prefix_total_usage_tokens=1 total_usage_tokens=256300 prefix_auto_compact_limit=2 auto_compact_limit=244800 prefix_token_limit_reached=false token_limit_reached=true
        """
        let output = "\(threadId)\(separator)\(Int(timestamp))\(separator)0\(separator)\(body)"

        let signal = CodexCompactionSignalResolver.latestSignals(fromSQLiteOutput: output)[threadId]

        XCTAssertEqual(signal?.totalUsageTokens, 256_300)
        XCTAssertEqual(signal?.autoCompactLimit, 244_800)
        XCTAssertEqual(signal?.tokenLimitReached, true)
    }

    func testCodexCompactionSignalResolverParsesBatchedThreadRows() {
        let separator = "\u{1F}"
        let firstThreadId = "11111111-1111-1111-1111-111111111111"
        let secondThreadId = "22222222-2222-2222-2222-222222222222"
        let firstBody = """
        session_loop{thread_id=\(firstThreadId)}:turn:run_turn: post sampling token usage turn_id=turn total_usage_tokens=256300 estimated_token_count=Some(177642) auto_compact_limit=244800 token_limit_reached=true
        """
        let secondBody = """
        session_loop{thread_id=\(secondThreadId)}:turn:run_turn: post sampling token usage turn_id=turn total_usage_tokens=20000 estimated_token_count=Some(18000) auto_compact_limit=244800 token_limit_reached=false
        """
        let output = [
            "\(firstThreadId)\(separator)1775000000\(separator)250000000\(separator)\(firstBody)",
            "\(secondThreadId)\(separator)1775000001\(separator)0\(separator)\(secondBody)",
        ].joined(separator: "\n")

        let signals = CodexCompactionSignalResolver.latestSignals(fromSQLiteOutput: output)

        XCTAssertEqual(signals[firstThreadId]?.tokenLimitReached, true)
        XCTAssertEqual(signals[firstThreadId]?.totalUsageTokens, 256_300)
        XCTAssertEqual(signals[secondThreadId]?.tokenLimitReached, false)
        XCTAssertEqual(signals[secondThreadId]?.totalUsageTokens, 20_000)
    }

    func testRefreshCodexCompactionSignalsMarksCurrentProcessingCodexSessionCompacting() {
        let store = SessionStore.shared
        let sessionId = "codex-compact-\(UUID().uuidString)"
        let transcriptPath = "/tmp/compact-rollout.jsonl"
        let session = store.process(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))
        let observedAt = Date()
        store.setCodexCompactionSignalResolverForTesting { threadIds in
            guard threadIds.contains(sessionId) else { return [:] }
            return [
                sessionId: CodexCompactionSignal(
                    observedAt: observedAt,
                    totalUsageTokens: 256_300,
                    estimatedTokenCount: 177_642,
                    autoCompactLimit: 244_800,
                    tokenLimitReached: true
                )
            ]
        }

        store.refreshCodexCompactionSignalsForTesting()

        XCTAssertEqual(session.codexCompactionSignal?.totalUsageTokens, 256_300)
        XCTAssertEqual(session.task, .compacting)
    }

    func testActiveCodexCompactionSignalPreventsWorkingEventFlicker() {
        let store = SessionStore.shared
        let sessionId = "codex-compact-no-flicker-\(UUID().uuidString)"
        let transcriptPath = "/tmp/compact-no-flicker-rollout.jsonl"
        let session = store.process(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))
        let compactingSignal = CodexCompactionSignal(
            observedAt: Date(),
            totalUsageTokens: 256_300,
            estimatedTokenCount: 177_642,
            autoCompactLimit: 244_800,
            tokenLimitReached: true
        )
        store.setCodexCompactionSignalResolverForTesting { threadIds in
            threadIds.contains(sessionId) ? [sessionId: compactingSignal] : [:]
        }

        store.refreshCodexCompactionSignalsForTesting()
        XCTAssertEqual(session.task, .compacting)

        _ = store.process(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: transcriptPath,
            event: .postToolUse,
            status: "processing",
            tool: "Bash",
            toolUseId: "tool-1"
        ))

        XCTAssertEqual(session.task, .compacting)
    }

    func testStaleCodexCompactionSignalDoesNotOverrideNewPrompt() {
        let store = SessionStore.shared
        let sessionId = "codex-stale-compact-\(UUID().uuidString)"
        let transcriptPath = "/tmp/stale-compact-rollout.jsonl"
        store.setCodexCompactionSignalResolverForTesting { threadIds in
            guard threadIds.contains(sessionId) else { return [:] }
            return [
                sessionId: CodexCompactionSignal(
                    observedAt: Date(timeIntervalSince1970: 1),
                    totalUsageTokens: 256_300,
                    estimatedTokenCount: nil,
                    autoCompactLimit: 244_800,
                    tokenLimitReached: true
                )
            ]
        }

        let session = store.process(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "new prompt"
        ))

        store.refreshCodexCompactionSignalsForTesting()

        XCTAssertNil(session.codexCompactionSignal)
        XCTAssertEqual(session.task, .working)
    }

    func testNewerNonLimitCodexCompactionSignalReturnsCompactingSessionToWorking() {
        let store = SessionStore.shared
        let sessionId = "codex-compact-clears-\(UUID().uuidString)"
        let transcriptPath = "/tmp/compact-clears-rollout.jsonl"
        let session = store.process(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))
        let compactingSignal = CodexCompactionSignal(
            observedAt: Date(),
            totalUsageTokens: 256_300,
            estimatedTokenCount: 177_642,
            autoCompactLimit: 244_800,
            tokenLimitReached: true
        )
        store.setCodexCompactionSignalResolverForTesting { threadIds in
            threadIds.contains(sessionId) ? [sessionId: compactingSignal] : [:]
        }

        store.refreshCodexCompactionSignalsForTesting()
        XCTAssertEqual(session.task, .compacting)

        let workingSignal = CodexCompactionSignal(
            observedAt: Date(),
            totalUsageTokens: 20_000,
            estimatedTokenCount: 18_000,
            autoCompactLimit: 244_800,
            tokenLimitReached: false
        )
        store.setCodexCompactionSignalResolverForTesting { threadIds in
            threadIds.contains(sessionId) ? [sessionId: workingSignal] : [:]
        }

        store.refreshCodexCompactionSignalsForTesting()

        XCTAssertEqual(session.task, .working)
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

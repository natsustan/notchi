import XCTest
@testable import notchi

final class AgentProviderAdapterTests: XCTestCase {
    private struct TestProviderAdapter: AgentProviderAdapter {
        nonisolated let provider: AgentProvider
        nonisolated let available: Bool
        nonisolated let installed: Bool

        nonisolated func installIfNeeded() -> Bool { installed }
        nonisolated func isProviderAvailable() -> Bool { available }
        nonisolated func isInstalled() -> Bool { installed }
        nonisolated func configureForLaunch() {}
        nonisolated func normalize(_ envelope: AgentHookEnvelope) -> HookEvent? { nil }
    }

    func testClaudeAdapterNormalizesEnvelopeIntoHookEvent() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": "claude-session",
            "cwd": "/tmp",
            "event": "SessionStart",
            "status": "waiting_for_input",
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        let event = ClaudeProviderAdapter().normalize(envelope)

        XCTAssertEqual(event?.provider, .claude)
        XCTAssertEqual(event?.event, .sessionStarted)
        XCTAssertEqual(event?.sessionId, "claude:claude-session")
    }

    func testCodexAdapterNormalizesSupportedEnvelopeIntoHookEvent() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": "codex-session",
            "cwd": "/tmp",
            "event": "UserPromptSubmit",
            "status": "processing",
            "user_prompt": "hello",
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        let event = CodexProviderAdapter().normalize(envelope)

        XCTAssertEqual(event?.provider, .codex)
        XCTAssertEqual(event?.event, .userPromptSubmitted)
        XCTAssertEqual(event?.userPrompt, "hello")
        XCTAssertEqual(event?.sessionId, "codex:codex-session")
    }

    func testCodexAdapterDropsUnsupportedEnvelope() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "session_id": "codex-session",
            "cwd": "/tmp",
            "event": "PermissionRequest",
            "status": "waiting_for_input",
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        XCTAssertNil(CodexProviderAdapter().normalize(envelope))
    }

    func testClaudeAdapterDropsUnknownEnvelope() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": "claude-session",
            "cwd": "/tmp",
            "event": "NotARealClaudeEvent",
            "status": "waiting_for_input",
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        XCTAssertNil(ClaudeProviderAdapter().normalize(envelope))
    }

    func testIntegrationCoordinatorReportsProviderAvailabilityFromAdapters() {
        let coordinator = IntegrationCoordinator(
            socketServer: SocketServer(socketPath: "/tmp/notchi-test-\(UUID().uuidString).sock"),
            adapters: [
                TestProviderAdapter(provider: .claude, available: false, installed: false),
                TestProviderAdapter(provider: .codex, available: true, installed: false),
            ]
        )

        XCTAssertFalse(coordinator.isProviderAvailable(for: .claude))
        XCTAssertTrue(coordinator.isProviderAvailable(for: .codex))
    }
}

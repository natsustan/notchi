import XCTest
@testable import notchi

final class AgentProviderAdapterTests: XCTestCase {
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
            "event": "PreToolUse",
            "status": "running_tool",
            "tool": "Bash",
            "model": "gpt-5.4",
        ])
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        let event = CodexProviderAdapter().normalize(envelope)

        XCTAssertEqual(event?.provider, .codex)
        XCTAssertEqual(event?.event, .preToolUse)
        XCTAssertEqual(event?.tool, "Bash")
        XCTAssertEqual(event?.model, "gpt-5.4")
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
}

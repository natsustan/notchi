import Foundation
import XCTest
@testable import notchi

final class ConversationParserTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchi-conversation-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        ConversationParser.claudeProjectsRootPath = tempDirectoryURL.path
    }

    override func tearDown() async throws {
        ConversationParser.claudeProjectsRootPath = ConversationParser.defaultClaudeProjectsRootPath
        ClaudeConfigDirectoryResolver.resetTestingHooks()
        try? FileManager.default.removeItem(at: tempDirectoryURL)
        tempDirectoryURL = nil
        try await super.tearDown()
    }

    func testParseIncrementalSkipsSyntheticAssistantMessages() async throws {
        let sessionId = "session-\(UUID().uuidString)"
        let cwd = "/tmp/notchi"
        let parser = ConversationParser.shared

        let sessionFilePath = ConversationParser.resolvedTranscriptPath(
            sessionId: sessionId,
            cwd: cwd,
            transcriptPath: nil
        )
        let sessionDirectory = URL(fileURLWithPath: sessionFilePath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let synthetic = assistantLine(
            uuid: "synthetic-1",
            text: "No response requested.",
            model: "<synthetic>"
        )
        let real = assistantLine(
            uuid: "assistant-1",
            text: "What's up?",
            model: "claude-opus-4-6"
        )
        try (synthetic + "\n" + real + "\n").write(toFile: sessionFilePath, atomically: true, encoding: .utf8)

        let result = await parser.parseIncremental(sessionId: sessionId, transcriptPath: sessionFilePath)

        XCTAssertFalse(result.interrupted)
        XCTAssertEqual(result.messages.map(\.text), ["What's up?"])
    }

    func testParseIncrementalReadsAssistantMessagesFromExplicitTranscriptPath() async throws {
        let sessionId = "transcript-\(UUID().uuidString)"
        let transcriptPath = tempDirectoryURL
            .appendingPathComponent("\(UUID().uuidString).jsonl")
            .path
        let parser = ConversationParser.shared

        let explicit = assistantLine(
            uuid: "assistant-explicit",
            text: "Hello from a custom transcript path",
            model: "claude-opus-4-6"
        )
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((explicit + "\n").utf8))

        let result = await parser.parseIncremental(
            sessionId: sessionId,
            transcriptPath: transcriptPath
        )
        await parser.resetState(for: sessionId)

        XCTAssertEqual(result.messages.map(\.text), ["Hello from a custom transcript path"])
        XCTAssertFalse(result.interrupted)
    }

    @MainActor
    func testResolvedTranscriptPathUsesConfiguredClaudeConfigDirectoryFallback() {
        let resolution = ClaudeConfigDirectoryResolution(
            path: "/tmp/custom-claude-config",
            source: .environment,
            shouldCache: true
        )
        ConversationParser.configureClaudeProjectsRootPath(using: resolution)

        let path = ConversationParser.resolvedTranscriptPath(
            sessionId: "session-123",
            cwd: "/Users/ruban/Developer/GitHub/notchi",
            transcriptPath: nil
        )

        XCTAssertEqual(
            path,
            "/tmp/custom-claude-config/projects/-Users-ruban-Developer-GitHub-notchi/session-123.jsonl"
        )
    }

    func testResolvedTranscriptPathFallsBackToDerivedSessionPathWhenMissingOrEmpty() {
        ConversationParser.claudeProjectsRootPath = "/tmp/config-projects"

        let missing = ConversationParser.resolvedTranscriptPath(
            sessionId: "session-123",
            cwd: "/Users/ruban/Developer/GitHub/notchi",
            transcriptPath: nil
        )
        let empty = ConversationParser.resolvedTranscriptPath(
            sessionId: "session-123",
            cwd: "/Users/ruban/Developer/GitHub/notchi",
            transcriptPath: "   "
        )

        XCTAssertEqual(missing, "/tmp/config-projects/-Users-ruban-Developer-GitHub-notchi/session-123.jsonl")
        XCTAssertEqual(empty, "/tmp/config-projects/-Users-ruban-Developer-GitHub-notchi/session-123.jsonl")
    }

    func testParseIncrementalReadsCodexAssistantMessagesFromExplicitTranscriptPath() async throws {
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: "codex-\(UUID().uuidString)")
        let transcriptPath = tempDirectoryURL
            .appendingPathComponent("\(UUID().uuidString)-codex.jsonl")
            .path
        let parser = ConversationParser.shared

        let line = """
        {"timestamp":"2026-04-11T04:00:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello from Codex"}],"phase":"commentary"}}
        """
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((line + "\n").utf8))

        let result = await parser.parseIncremental(sessionKey: sessionKey, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionKey)

        XCTAssertEqual(result.messages.map(\.text), ["Hello from Codex"])
        XCTAssertFalse(result.interrupted)
    }

    func testParseIncrementalReadsCodexExecCommandEventsFromExplicitTranscriptPath() async throws {
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: "codex-\(UUID().uuidString)")
        let transcriptPath = tempDirectoryURL
            .appendingPathComponent("\(UUID().uuidString)-codex-tools.jsonl")
            .path
        let parser = ConversationParser.shared

        let contents = """
        {"timestamp":"2026-04-11T04:00:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"pwd\\",\\"max_output_tokens\\":200}","call_id":"call-123"}}
        {"timestamp":"2026-04-11T04:00:01.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-123","output":"Process exited with code 0\\nOutput:\\n/Users/ruban/Developer/GitHub/notchi\\n"}}
        """
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((contents + "\n").utf8))

        let result = await parser.parseIncremental(sessionKey: sessionKey, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionKey)

        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.events.first?.event, .preToolUse)
        XCTAssertEqual(result.events.first?.tool, "Bash")
        XCTAssertEqual(result.events.first?.toolUseId, "call-123")
        XCTAssertEqual(result.events.first?.toolInput?["command"]?.value as? String, "pwd")
        XCTAssertEqual(result.events.last?.event, .postToolUse)
        XCTAssertEqual(result.events.last?.status, "processing")
        XCTAssertEqual(result.events.last?.toolUseId, "call-123")
    }

    func testResolvedTranscriptPathReturnsNilForCodexWithoutTranscriptPath() {
        let path = ConversationParser.resolvedTranscriptPath(
            for: .codex,
            sessionId: "codex-session",
            cwd: "/Users/ruban/Developer/GitHub/notchi",
            transcriptPath: nil
        )

        XCTAssertNil(path)
    }

    func testCodexAssistantMessageIdentifiersAreStableAcrossParserResets() async throws {
        let sessionKey = ProviderSessionKey(provider: .codex, rawSessionId: "codex-\(UUID().uuidString)")
        let transcriptPath = tempDirectoryURL
            .appendingPathComponent("\(UUID().uuidString)-stable-id.jsonl")
            .path
        let parser = ConversationParser.shared

        let line = """
        {"timestamp":"2026-04-11T04:00:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Stable Codex ID"}],"phase":"commentary"}}
        """
        FileManager.default.createFile(atPath: transcriptPath, contents: Data((line + "\n").utf8))

        let first = await parser.parseIncremental(sessionKey: sessionKey, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionKey)
        let second = await parser.parseIncremental(sessionKey: sessionKey, transcriptPath: transcriptPath)
        await parser.resetState(for: sessionKey)

        XCTAssertEqual(first.messages.count, 1)
        XCTAssertEqual(second.messages.count, 1)
        XCTAssertEqual(first.messages.first?.id, second.messages.first?.id)
    }

    private func assistantLine(uuid: String, text: String, model: String) -> String {
        let timestamp = "2026-04-07T09:50:04.954Z"
        return """
        {"type":"assistant","uuid":"\(uuid)","timestamp":"\(timestamp)","message":{"model":"\(model)","role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
        """
    }
}

import CryptoKit
import Foundation

struct ParseResult {
    let messages: [AssistantMessage]
    let interrupted: Bool
    let events: [ParsedSessionEvent]

    init(messages: [AssistantMessage], interrupted: Bool, events: [ParsedSessionEvent] = []) {
        self.messages = messages
        self.interrupted = interrupted
        self.events = events
    }
}

struct ParsedSessionEvent: Sendable {
    let id: String
    let event: NormalizedAgentEvent
    let status: String
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
}

private struct CodexToolCall: Sendable {
    let tool: String
    let input: [String: AnyCodable]?
}

actor ConversationParser {
    static let shared = ConversationParser()
    nonisolated static let defaultClaudeProjectsRootPath = "\(NSHomeDirectory())/.claude/projects"
    nonisolated(unsafe) static var claudeProjectsRootPath = defaultClaudeProjectsRootPath

    private var lastFileOffset: [String: UInt64] = [:]
    private var seenMessageIds: [String: Set<String>] = [:]
    private var seenEventIds: [String: Set<String>] = [:]
    private var codexToolCallsById: [String: [String: CodexToolCall]] = [:]

    private static let emptyResult = ParseResult(messages: [], interrupted: false, events: [])

    nonisolated static func configureClaudeProjectsRootPath(using claudeConfig: ClaudeConfigDirectoryResolution) {
        claudeProjectsRootPath = claudeConfig.projectsDirectoryURL.path
    }

    nonisolated static func resolvedTranscriptPath(
        for provider: AgentProvider,
        sessionId: String,
        cwd: String,
        transcriptPath: String?
    ) -> String? {
        if let trimmedPath = transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedPath.isEmpty {
            return trimmedPath
        }

        guard provider.capabilities.supportsDerivedTranscriptFallback else {
            return nil
        }

        return derivedClaudeTranscriptPath(sessionId: sessionId, cwd: cwd)
    }

    nonisolated static func resolvedTranscriptPath(sessionId: String, cwd: String, transcriptPath: String?) -> String {
        resolvedTranscriptPath(for: .claude, sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath)
            ?? derivedClaudeTranscriptPath(sessionId: sessionId, cwd: cwd)
    }

    func parseIncremental(sessionKey: ProviderSessionKey, transcriptPath: String) -> ParseResult {
        let stateKey = Self.stateKey(for: sessionKey)

        guard FileManager.default.fileExists(atPath: transcriptPath) else {
            return Self.emptyResult
        }

        guard let fileHandle = FileHandle(forReadingAtPath: transcriptPath) else {
            return Self.emptyResult
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return Self.emptyResult
        }

        var currentOffset = lastFileOffset[stateKey] ?? 0

        if fileSize < currentOffset {
            currentOffset = 0
            seenMessageIds[stateKey] = []
            seenEventIds[stateKey] = []
            codexToolCallsById[stateKey] = [:]
        }

        if fileSize == currentOffset {
            return Self.emptyResult
        }

        do {
            try fileHandle.seek(toOffset: currentOffset)
        } catch {
            return Self.emptyResult
        }

        guard let newData = try? fileHandle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return Self.emptyResult
        }

        var messages: [AssistantMessage] = []
        var events: [ParsedSessionEvent] = []
        var interrupted = false
        var seen = seenMessageIds[stateKey] ?? []
        var seenEvents = seenEventIds[stateKey] ?? []
        var codexToolCalls = codexToolCallsById[stateKey] ?? [:]
        let lines = newContent.components(separatedBy: "\n")

        for line in lines where !line.isEmpty {
            switch sessionKey.provider {
            case .claude:
                if !interrupted &&
                    line.contains("\"type\":\"user\"") &&
                    line.contains("\"text\":\"[Request interrupted by user") {
                    interrupted = true
                }

                guard let message = Self.parseClaudeAssistantMessage(from: line) else { continue }
                guard !seen.contains(message.id) else { continue }

                seen.insert(message.id)
                messages.append(message)

            case .codex:
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                if let message = Self.parseCodexAssistantMessage(from: json, originalLine: line),
                   !seen.contains(message.id) {
                    seen.insert(message.id)
                    messages.append(message)
                }

                if let event = Self.parseCodexSessionEvent(from: json, toolCallsById: &codexToolCalls),
                   !seenEvents.contains(event.id) {
                    seenEvents.insert(event.id)
                    events.append(event)
                }
            }
        }

        lastFileOffset[stateKey] = fileSize
        seenMessageIds[stateKey] = seen
        seenEventIds[stateKey] = seenEvents
        codexToolCallsById[stateKey] = codexToolCalls

        return ParseResult(messages: messages, interrupted: interrupted, events: events)
    }

    func parseIncremental(sessionId: String, transcriptPath: String) -> ParseResult {
        parseIncremental(
            sessionKey: ProviderSessionKey(provider: .claude, rawSessionId: sessionId),
            transcriptPath: transcriptPath
        )
    }

    func resetState(for sessionKey: ProviderSessionKey) {
        let stateKey = Self.stateKey(for: sessionKey)
        lastFileOffset.removeValue(forKey: stateKey)
        seenMessageIds.removeValue(forKey: stateKey)
        seenEventIds.removeValue(forKey: stateKey)
        codexToolCallsById.removeValue(forKey: stateKey)
    }

    func resetState(for sessionId: String) {
        resetState(for: ProviderSessionKey(provider: .claude, rawSessionId: sessionId))
    }

    func markCurrentPosition(sessionKey: ProviderSessionKey, transcriptPath: String) {
        let stateKey = Self.stateKey(for: sessionKey)

        guard let fileHandle = FileHandle(forReadingAtPath: transcriptPath) else {
            lastFileOffset[stateKey] = 0
            seenMessageIds[stateKey] = []
            seenEventIds[stateKey] = []
            codexToolCallsById[stateKey] = [:]
            return
        }
        defer { try? fileHandle.close() }

        let fileSize = (try? fileHandle.seekToEnd()) ?? 0
        lastFileOffset[stateKey] = fileSize
        seenMessageIds[stateKey] = []
        seenEventIds[stateKey] = []
        codexToolCallsById[stateKey] = [:]
    }

    func markCurrentPosition(sessionId: String, transcriptPath: String) {
        markCurrentPosition(
            sessionKey: ProviderSessionKey(provider: .claude, rawSessionId: sessionId),
            transcriptPath: transcriptPath
        )
    }

    private static func parseClaudeAssistantMessage(from line: String) -> AssistantMessage? {
        guard line.contains("\"type\":\"assistant\""),
              let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = json["type"] as? String,
              type == "assistant",
              let uuid = json["uuid"] as? String else {
            return nil
        }

        if json["isMeta"] as? Bool == true {
            return nil
        }

        guard let messageDict = json["message"] as? [String: Any] else {
            return nil
        }

        if messageDict["model"] as? String == "<synthetic>" {
            return nil
        }

        let timestamp = parseTimestamp(from: json["timestamp"] as? String)
        let fullText = extractClaudeText(from: messageDict)
        guard !fullText.isEmpty else { return nil }

        return AssistantMessage(id: uuid, text: fullText, timestamp: timestamp)
    }

    private static func parseCodexAssistantMessage(from json: [String: Any], originalLine: String) -> AssistantMessage? {
        guard let type = json["type"] as? String,
              type == "response_item",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              payload["role"] as? String == "assistant" else {
            return nil
        }

        let timestampString = json["timestamp"] as? String
        let timestamp = parseTimestamp(from: timestampString)
        let phase = payload["phase"] as? String ?? "assistant"

        guard let contentBlocks = payload["content"] as? [[String: Any]] else {
            return nil
        }

        let textParts = contentBlocks.compactMap { block -> String? in
            guard let blockType = block["type"] as? String else { return nil }
            guard blockType == "output_text" || blockType == "text" else { return nil }
            return block["text"] as? String
        }

        let fullText = textParts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else { return nil }

        let identifier = "\(phase)-\(timestampString ?? "unknown")-\(stableContentDigest(for: originalLine))"
        return AssistantMessage(id: identifier, text: fullText, timestamp: timestamp)
    }

    private static func parseCodexSessionEvent(
        from json: [String: Any],
        toolCallsById: inout [String: CodexToolCall]
    ) -> ParsedSessionEvent? {
        guard let type = json["type"] as? String,
              type == "response_item",
              let payload = json["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return nil
        }

        switch payloadType {
        case "function_call":
            guard let callID = payload["call_id"] as? String,
                  let toolCall = parseCodexToolCall(from: payload) else {
                return nil
            }

            toolCallsById[callID] = toolCall
            return ParsedSessionEvent(
                id: "tool-start-\(callID)",
                event: .preToolUse,
                status: "running_tool",
                tool: toolCall.tool,
                toolInput: toolCall.input,
                toolUseId: callID
            )

        case "function_call_output":
            guard let callID = payload["call_id"] as? String,
                  let toolCall = toolCallsById.removeValue(forKey: callID) else {
                return nil
            }

            let output = payload["output"] as? String ?? ""
            return ParsedSessionEvent(
                id: "tool-end-\(callID)",
                event: .postToolUse,
                status: isSuccessfulCodexToolOutput(output) ? "processing" : "error",
                tool: toolCall.tool,
                toolInput: nil,
                toolUseId: callID
            )

        default:
            return nil
        }
    }

    private static func parseCodexToolCall(from payload: [String: Any]) -> CodexToolCall? {
        guard let name = payload["name"] as? String else { return nil }

        switch name {
        case "exec_command":
            let command = parseCodexExecCommand(from: payload["arguments"] as? String)
            let input = command.map { ["command": AnyCodable($0)] }
            return CodexToolCall(tool: "Bash", input: input)

        default:
            return nil
        }
    }

    private static func parseCodexExecCommand(from arguments: String?) -> String? {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json["cmd"] as? String
    }

    private static func isSuccessfulCodexToolOutput(_ output: String) -> Bool {
        if let match = output.firstMatch(of: /Process exited with code (\d+)/) {
            return match.1 == "0"
        }

        return !output.contains("Process exited with signal")
    }

    private static func extractClaudeText(from messageDict: [String: Any]) -> String {
        var textParts: [String] = []

        if let content = messageDict["content"] as? String {
            if !content.hasPrefix("<command-name>") &&
                !content.hasPrefix("[Request interrupted") {
                textParts.append(content)
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                guard let blockType = block["type"] as? String else { continue }

                if blockType == "text", let text = block["text"] as? String,
                   !text.hasPrefix("[Request interrupted") {
                    textParts.append(text)
                }
            }
        }

        return textParts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTimestamp(from timestampString: String?) -> Date {
        guard let timestampString else { return Date() }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestampString) ?? Date()
    }

    private static func stableContentDigest(for line: String) -> String {
        // WHY: Swift's hashValue is seeded per process, so dedupe IDs would change
        // across app restarts; a short SHA256 prefix keeps them deterministic.
        let digest = SHA256.hash(data: Data(line.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func derivedClaudeTranscriptPath(sessionId: String, cwd: String) -> String {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return "\(claudeProjectsRootPath)/\(projectDir)/\(sessionId).jsonl"
    }

    private static func stateKey(for sessionKey: ProviderSessionKey) -> String {
        sessionKey.stableId
    }
}

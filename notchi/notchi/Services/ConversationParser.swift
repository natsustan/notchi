import Foundation

struct ParseResult {
    let messages: [AssistantMessage]
    let interrupted: Bool
}

actor ConversationParser {
    static let shared = ConversationParser()
    static let defaultClaudeProjectsRootPath = "\(NSHomeDirectory())/.claude/projects"
    static var claudeProjectsRootPath = defaultClaudeProjectsRootPath

    private var lastFileOffset: [String: UInt64] = [:]
    private var seenMessageIds: [String: Set<String>] = [:]

    private static let emptyResult = ParseResult(messages: [], interrupted: false)

    @MainActor
    static func configureClaudeProjectsRootPath(using claudeConfig: ClaudeConfigDirectoryResolution) {
        claudeProjectsRootPath = claudeConfig.projectsDirectoryURL.path
    }

    static func resolvedTranscriptPath(
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

    static func resolvedTranscriptPath(sessionId: String, cwd: String, transcriptPath: String?) -> String {
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
        var interrupted = false
        var seen = seenMessageIds[stateKey] ?? []
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
                guard let message = Self.parseCodexAssistantMessage(from: line) else { continue }
                guard !seen.contains(message.id) else { continue }

                seen.insert(message.id)
                messages.append(message)
            }
        }

        lastFileOffset[stateKey] = fileSize
        seenMessageIds[stateKey] = seen

        return ParseResult(messages: messages, interrupted: interrupted)
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
    }

    func resetState(for sessionId: String) {
        resetState(for: ProviderSessionKey(provider: .claude, rawSessionId: sessionId))
    }

    func markCurrentPosition(sessionKey: ProviderSessionKey, transcriptPath: String) {
        let stateKey = Self.stateKey(for: sessionKey)

        guard let fileHandle = FileHandle(forReadingAtPath: transcriptPath) else {
            lastFileOffset[stateKey] = 0
            seenMessageIds[stateKey] = []
            return
        }
        defer { try? fileHandle.close() }

        let fileSize = (try? fileHandle.seekToEnd()) ?? 0
        lastFileOffset[stateKey] = fileSize
        seenMessageIds[stateKey] = []
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

    private static func parseCodexAssistantMessage(from line: String) -> AssistantMessage? {
        guard let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = json["type"] as? String,
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

        let identifier = "\(phase)-\(timestampString ?? "unknown")-\(line.hashValue)"
        return AssistantMessage(id: identifier, text: fullText, timestamp: timestamp)
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

    private static func derivedClaudeTranscriptPath(sessionId: String, cwd: String) -> String {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return "\(claudeProjectsRootPath)/\(projectDir)/\(sessionId).jsonl"
    }

    private static func stateKey(for sessionKey: ProviderSessionKey) -> String {
        sessionKey.stableId
    }
}

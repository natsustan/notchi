import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SessionStore")

extension Notification.Name {
    static let sessionStoreActiveSessionCountDidChange = Notification.Name("sessionStoreActiveSessionCountDidChange")
}

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [ProviderSessionKey: SessionData] = [:]
    private(set) var selectedSessionKey: ProviderSessionKey?
    private var displaySessionNumbersById: [String: Int] = [:]
    private var resolveCodexMetadata: @Sendable (String) -> CodexThreadMetadata? = { transcriptPath in
        CodexThreadMetadataResolver.metadata(for: transcriptPath)
    }

    private init() {}

    var selectedSessionId: String? {
        selectedSessionKey?.stableId
    }

    var sortedSessions: [SessionData] {
        sessions.values.sorted { lhs, rhs in
            if lhs.isProcessing != rhs.isProcessing {
                return lhs.isProcessing
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    var activeSessionCount: Int {
        sessions.count
    }

    var selectedSession: SessionData? {
        guard let selectedSessionKey else { return nil }
        return sessions[selectedSessionKey]
    }

    var effectiveSession: SessionData? {
        if let selected = selectedSession {
            return selected
        }
        if sessions.count == 1 {
            return sessions.values.first
        }
        return sortedSessions.first
    }

    func selectSession(_ sessionKey: ProviderSessionKey) {
        guard sessions[sessionKey] != nil else { return }
        selectedSessionKey = sessionKey
        logger.info("Selected session: \(sessionKey.stableId, privacy: .public)")
    }

    func selectSession(matchingStableId stableId: String) {
        guard let sessionKey = ProviderSessionKey(stableId: stableId) else { return }
        selectSession(sessionKey)
    }

    func clearSelectedSession() {
        selectedSessionKey = nil
        logger.info("Selected session: nil")
    }

    func process(_ event: HookEvent, sessionStartTimeOverride: Date? = nil) -> SessionData {
        let isInteractive = event.interactive ?? true
        let session = getOrCreateSession(
            sessionKey: event.sessionKey,
            cwd: event.cwd,
            isInteractive: isInteractive,
            sessionStartTime: sessionStartTimeOverride
        )
        let isProcessing = Self.isProcessingStatus(event.status)
        session.updateProcessingState(isProcessing: isProcessing)

        if let mode = event.permissionMode {
            session.updatePermissionMode(mode)
        }

        session.updateCodexRuntime(processId: event.codexProcessId, origin: event.codexOrigin)
        if event.provider == .codex, let transcriptPath = event.transcriptPath {
            session.updateCodexThreadMetadata(
                transcriptPath: transcriptPath,
                metadata: nil
            )
        }

        switch event.event {
        case .userPromptSubmitted:
            if let prompt = event.userPrompt {
                session.recordUserPrompt(prompt)
            }
            session.clearRecentEvents()
            session.clearAssistantMessages()
            session.clearPendingQuestions()
            if Self.isLocalSlashCommand(event.userPrompt) {
                session.updateTask(.idle)
            } else {
                session.advanceSpinnerVerbForReply()
                session.updateTask(.working)
            }

        case .preCompact:
            session.updateTask(.compacting)

        case .sessionStarted:
            if isProcessing {
                session.updateTask(.working)
            }

        case .preToolUse:
            let toolInput = event.toolInput?.mapValues { $0.value }
            session.recordPreToolUse(tool: event.tool, toolInput: toolInput, toolUseId: event.toolUseId)
            if event.tool == "AskUserQuestion" {
                session.updateTask(.waiting)
                session.setPendingQuestions(Self.parseQuestions(from: event.toolInput))
            } else {
                session.clearPendingQuestions()
                session.updateTask(.working)
            }

        case .permissionRequest:
            let question = Self.buildPermissionQuestion(tool: event.tool, toolInput: event.toolInput)
            session.updateTask(.waiting)
            session.setPendingQuestions([question])

        case .postToolUse:
            let success = event.status != "error"
            session.recordPostToolUse(tool: event.tool, toolUseId: event.toolUseId, success: success)
            session.clearPendingQuestions()
            session.updateTask(.working)

        case .stop, .subagentStop:
            session.clearPendingQuestions()
            session.updateTask(.idle)

        case .sessionEnded:
            session.endSession()
            removeSession(event.sessionKey)
        }

        return session
    }

    func displaySessionNumber(for session: SessionData) -> Int {
        displaySessionNumbersById[session.id] ?? 1
    }

    func displaySessionLabel(for session: SessionData) -> String {
        "\(session.projectName) #\(displaySessionNumber(for: session))"
    }

    func displayTitle(for session: SessionData) -> String {
        let label = displaySessionLabel(for: session)
        if let detail = session.codexTitle ?? session.lastUserPrompt {
            return "\(label) - \(detail)"
        }
        return label
    }

    private func getOrCreateSession(
        sessionKey: ProviderSessionKey,
        cwd: String,
        isInteractive: Bool,
        sessionStartTime: Date?
    ) -> SessionData {
        if let existing = sessions[sessionKey] {
            return existing
        }

        let existingXPositions = sessions.values.map(\.spriteXPosition)
        let session = SessionData(
            sessionKey: sessionKey,
            cwd: cwd,
            isInteractive: isInteractive,
            existingXPositions: existingXPositions,
            sessionStartTime: sessionStartTime ?? Date()
        )
        sessions[sessionKey] = session
        recomputeDisplaySessionNumbers()
        logger.info(
            "Created \(session.provider.rawValue, privacy: .public) session #\(self.displaySessionNumber(for: session)): \(session.rawSessionId, privacy: .public) at \(cwd, privacy: .public)"
        )
        postActiveSessionCountChange()

        if activeSessionCount == 1 {
            selectedSessionKey = session.sessionKey
        } else {
            selectedSessionKey = nil
        }

        return session
    }

    private func removeSession(_ sessionKey: ProviderSessionKey) {
        sessions.removeValue(forKey: sessionKey)
        recomputeDisplaySessionNumbers()
        logger.info("Removed session: \(sessionKey.stableId, privacy: .public)")
        postActiveSessionCountChange()

        if selectedSessionKey == sessionKey {
            selectedSessionKey = nil
        }

        if selectedSessionKey == nil, activeSessionCount == 1 {
            selectedSessionKey = sessions.keys.first
        }
    }

    func dismissSession(_ sessionKey: ProviderSessionKey) {
        sessions[sessionKey]?.endSession()
        removeSession(sessionKey)
    }

    func dismissSession(matchingStableId stableId: String) {
        guard let sessionKey = ProviderSessionKey(stableId: stableId) else { return }
        dismissSession(sessionKey)
    }

    func codexThreadMetadataRequests() -> [CodexThreadMetadataRequest] {
        sessions.values.compactMap { session in
            guard let transcriptPath = session.codexTranscriptPath else { return nil }
            return CodexThreadMetadataRequest(
                sessionKey: session.sessionKey,
                transcriptPath: transcriptPath
            )
        }
    }

    func resolveCodexThreadMetadata(_ requests: [CodexThreadMetadataRequest]) async -> [CodexThreadMetadataUpdate] {
        let resolver = resolveCodexMetadata
        return await Task.detached(priority: .utility) {
            requests.map { request in
                CodexThreadMetadataUpdate(
                    sessionKey: request.sessionKey,
                    transcriptPath: request.transcriptPath,
                    metadata: resolver(request.transcriptPath)
                )
            }
        }.value
    }

    func applyCodexThreadMetadata(_ updates: [CodexThreadMetadataUpdate]) -> [SessionData] {
        var archivedSessions: [SessionData] = []

        for update in updates {
            guard let session = sessions[update.sessionKey],
                  session.codexTranscriptPath == update.transcriptPath else {
                continue
            }

            session.updateCodexThreadMetadata(
                transcriptPath: update.transcriptPath,
                metadata: update.metadata
            )

            if session.codexArchived {
                archivedSessions.append(session)
            }
        }

        return archivedSessions
    }

    func recordAssistantMessages(_ messages: [AssistantMessage], for sessionKey: ProviderSessionKey) {
        guard let session = sessions[sessionKey] else { return }
        session.recordAssistantMessages(messages)
    }

    func session(for sessionKey: ProviderSessionKey) -> SessionData? {
        sessions[sessionKey]
    }

#if DEBUG
    func refreshCodexThreadMetadataForTesting() -> [SessionData] {
        let updates = codexThreadMetadataRequests().map { request in
            CodexThreadMetadataUpdate(
                sessionKey: request.sessionKey,
                transcriptPath: request.transcriptPath,
                metadata: resolveCodexMetadata(request.transcriptPath)
            )
        }
        return applyCodexThreadMetadata(updates)
    }

    func setCodexMetadataResolverForTesting(_ resolver: @escaping @Sendable (String) -> CodexThreadMetadata?) {
        resolveCodexMetadata = resolver
    }

    func resetTestingHooks() {
        resolveCodexMetadata = { transcriptPath in
            CodexThreadMetadataResolver.metadata(for: transcriptPath)
        }
    }
#endif

    private func postActiveSessionCountChange() {
        NotificationCenter.default.post(
            name: .sessionStoreActiveSessionCountDidChange,
            object: self
        )
    }

    private func recomputeDisplaySessionNumbers() {
        let groupedSessions = Dictionary(grouping: sessions.values, by: \.projectName)
        var displayNumbers: [String: Int] = [:]

        for projectSessions in groupedSessions.values {
            let orderedSessions = projectSessions.sorted { lhs, rhs in
                if lhs.sessionStartTime != rhs.sessionStartTime {
                    return lhs.sessionStartTime < rhs.sessionStartTime
                }
                return lhs.id < rhs.id
            }

            for (index, session) in orderedSessions.enumerated() {
                displayNumbers[session.id] = index + 1
            }
        }

        displaySessionNumbersById = displayNumbers
    }

    private static func parseQuestions(from toolInput: [String: AnyCodable]?) -> [PendingQuestion] {
        guard let input = toolInput?.mapValues({ $0.value }),
              let questions = input["questions"] as? [[String: Any]] else { return [] }

        return questions.compactMap { q in
            guard let questionText = q["question"] as? String else { return nil }
            let header = q["header"] as? String
            let rawOptions = q["options"] as? [[String: Any]] ?? []
            let options = rawOptions.compactMap { opt -> (label: String, description: String?)? in
                guard let label = opt["label"] as? String else { return nil }
                return (label: label, description: opt["description"] as? String)
            }
            return PendingQuestion(question: questionText, header: header, options: options)
        }
    }

    private static let localSlashCommands: Set<String> = [
        "/clear", "/help", "/cost", "/status",
        "/vim", "/fast", "/model", "/login", "/logout",
    ]

    static func isLocalSlashCommand(_ prompt: String?) -> Bool {
        guard let prompt, prompt.hasPrefix("/") else { return false }
        let command = String(prompt.prefix(while: { !$0.isWhitespace }))
        return localSlashCommands.contains(command)
    }

    private static func buildPermissionQuestion(tool: String?, toolInput: [String: AnyCodable]?) -> PendingQuestion {
        let toolName = tool ?? "Tool"
        let input = toolInput?.mapValues { $0.value }
        let description = SessionEvent.deriveDescription(tool: tool, toolInput: input)
        return PendingQuestion(
            question: description ?? "\(toolName) wants to proceed",
            header: "Permission Request",
            // Claude Code permission prompts always present these three choices
            options: [
                (label: "Yes", description: nil),
                (label: "Yes, and don't ask again", description: nil),
                (label: "No", description: nil),
            ]
        )
    }

    private static func isProcessingStatus(_ status: String) -> Bool {
        status != "waiting_for_input" && status != "ended"
    }
}

nonisolated struct CodexThreadMetadata: Sendable, Equatable {
    let title: String?
    let archived: Bool
}

nonisolated struct CodexThreadMetadataRequest: Sendable, Equatable {
    let sessionKey: ProviderSessionKey
    let transcriptPath: String
}

nonisolated struct CodexThreadMetadataUpdate: Sendable, Equatable {
    let sessionKey: ProviderSessionKey
    let transcriptPath: String
    let metadata: CodexThreadMetadata?
}

nonisolated enum CodexThreadMetadataResolver {
    private static var codexDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private static var stateURL: URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: codexDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        return entries.compactMap { url -> (version: Int, url: URL)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("state_"),
                  url.pathExtension == "sqlite",
                  let version = Int(name.dropFirst("state_".count)) else {
                return nil
            }
            return (version, url)
        }
        .max { lhs, rhs in lhs.version < rhs.version }?
        .url
    }

    static func metadata(for transcriptPath: String) -> CodexThreadMetadata? {
        let trimmedPath = transcriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty,
              let stateURL,
              FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }

        let escapedPath = trimmedPath.replacingOccurrences(of: "'", with: "''")
        let threadIdClause = codexThreadId(from: trimmedPath).map { threadId in
            let escapedThreadId = threadId.replacingOccurrences(of: "'", with: "''")
            return " OR id = '\(escapedThreadId)'"
        } ?? ""
        let query = "SELECT hex(title), archived FROM threads WHERE rollout_path = '\(escapedPath)'\(threadIdClause) LIMIT 1;"
        guard let output = runSQLite(query: query, databasePath: stateURL.path) else {
            return nil
        }

        let parts = output.split(separator: "\u{1F}", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        let title = decodeHexString(String(parts[0]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let archived = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) != "0"

        return CodexThreadMetadata(
            title: title?.isEmpty == false ? title : nil,
            archived: archived
        )
    }

    private static func runSQLite(query: String, databasePath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", "-noheader", "-separator", "\u{1F}", databasePath, query]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return output?.isEmpty == false ? output : nil
    }

    private static func codexThreadId(from transcriptPath: String) -> String? {
        let fileName = URL(fileURLWithPath: transcriptPath).deletingPathExtension().lastPathComponent
        let components = fileName.split(separator: "-")
        guard components.count >= 5 else { return nil }

        let idComponents = components.suffix(5)
        let id = idComponents.joined(separator: "-")
        return id.count == 36 ? id : nil
    }

    private static func decodeHexString(_ hexString: String) -> String? {
        guard !hexString.isEmpty, hexString.count.isMultiple(of: 2) else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)

        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = nextIndex
        }

        return String(bytes: bytes, encoding: .utf8)
    }
}

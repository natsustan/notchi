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
        if let prompt = session.lastUserPrompt {
            return "\(label) - \(prompt)"
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

    func recordAssistantMessages(_ messages: [AssistantMessage], for sessionKey: ProviderSessionKey) {
        guard let session = sessions[sessionKey] else { return }
        session.recordAssistantMessages(messages)
    }

    func session(for sessionKey: ProviderSessionKey) -> SessionData? {
        sessions[sessionKey]
    }

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

import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SessionStore")

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [String: SessionData] = [:]
    private(set) var selectedSessionId: String?
    private var nextSessionNumber = 1

    private init() {}

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
        guard let id = selectedSessionId else { return nil }
        return sessions[id]
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

    func selectSession(_ sessionId: String?) {
        if let id = sessionId {
            guard sessions[id] != nil else { return }
        }
        selectedSessionId = sessionId
        logger.info("Selected session: \(sessionId ?? "nil", privacy: .public)")
    }

    func process(_ event: HookEvent) -> SessionData {
        let session = getOrCreateSession(sessionId: event.sessionId, cwd: event.cwd)
        let isProcessing = event.status != "waiting_for_input"
        session.updateProcessingState(isProcessing: isProcessing)

        if let mode = event.permissionMode {
            session.updatePermissionMode(mode)
        }

        switch event.event {
        case "UserPromptSubmit":
            if let prompt = event.userPrompt {
                session.recordUserPrompt(prompt)
            }
            session.clearAssistantMessages()
            session.updateState(.working)

        case "PreCompact":
            session.updateState(.compacting)

        case "SessionStart":
            session.updateState(.working)

        case "PreToolUse":
            let toolInput = event.toolInput?.mapValues { $0.value }
            session.recordPreToolUse(tool: event.tool, toolInput: toolInput, toolUseId: event.toolUseId)
            if event.tool == "AskUserQuestion" {
                session.updateState(.waiting)
                session.setPendingQuestions(Self.parseQuestions(from: event.toolInput))
            } else {
                session.updateState(.working)
            }

        case "PermissionRequest":
            session.updateState(.waiting)

        case "PostToolUse":
            let success = event.status != "error"
            session.recordPostToolUse(tool: event.tool, toolUseId: event.toolUseId, success: success)
            session.clearPendingQuestions()

        case "Stop", "SubagentStop":
            session.updateState(.idle)

        case "SessionEnd":
            session.endSession()
            removeSession(event.sessionId)

        default:
            if !isProcessing && session.state != .idle {
                session.updateState(.idle)
            }
        }

        return session
    }

    func recordAssistantMessages(_ messages: [AssistantMessage], for sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.recordAssistantMessages(messages)
    }

    private func getOrCreateSession(sessionId: String, cwd: String) -> SessionData {
        if let existing = sessions[sessionId] {
            return existing
        }

        let sessionNumber = nextSessionNumber
        nextSessionNumber += 1
        let existingXPositions = sessions.values.map(\.spriteXPosition)
        let session = SessionData(sessionId: sessionId, cwd: cwd, sessionNumber: sessionNumber, existingXPositions: existingXPositions)
        sessions[sessionId] = session
        logger.info("Created session #\(sessionNumber): \(sessionId, privacy: .public) at \(cwd, privacy: .public)")

        if activeSessionCount == 1 {
            selectedSessionId = sessionId
        } else {
            selectedSessionId = nil
        }

        return session
    }

    private func removeSession(_ sessionId: String) {
        sessions.removeValue(forKey: sessionId)
        logger.info("Removed session: \(sessionId, privacy: .public)")

        if selectedSessionId == sessionId {
            selectedSessionId = nil
        }

        if activeSessionCount == 1 {
            selectedSessionId = sessions.keys.first
        }
    }

    func dismissSession(_ sessionId: String) {
        sessions[sessionId]?.endSession()
        removeSession(sessionId)
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
}

import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SessionData")

@MainActor
@Observable
final class SessionData: Identifiable {
    let id: String
    let cwd: String
    let sessionNumber: Int
    let sessionStartTime: Date

    private(set) var state: NotchiState = .idle
    private(set) var isProcessing: Bool = false
    private(set) var lastActivity: Date
    private(set) var recentEvents: [SessionEvent] = []
    private(set) var recentAssistantMessages: [AssistantMessage] = []
    private(set) var lastUserPrompt: String?
    private(set) var promptSubmitTime: Date?
    private(set) var permissionMode: String = "default"

    private var durationTimer: Task<Void, Never>?
    private(set) var formattedDuration: String = "0m 00s"

    private static let maxEvents = 20
    private static let maxAssistantMessages = 10

    var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    var currentModeDisplay: String? {
        switch permissionMode {
        case "plan": return "Plan Mode"
        case "acceptEdits": return "Accept Edits"
        case "dontAsk": return "Don't Ask"
        case "bypassPermissions": return "Bypass"
        default: return nil
        }
    }

    var displayTitle: String {
        let title = "\(projectName) #\(sessionNumber)"
        if let prompt = lastUserPrompt {
            return "\(title) - \(prompt)"
        }
        return title
    }

    var activityPreview: String? {
        if let lastEvent = recentEvents.last {
            return lastEvent.description ?? lastEvent.tool ?? lastEvent.type
        }
        if let lastMessage = recentAssistantMessages.last {
            return String(lastMessage.text.prefix(50))
        }
        return nil
    }

    init(sessionId: String, cwd: String, sessionNumber: Int) {
        self.id = sessionId
        self.cwd = cwd
        self.sessionNumber = sessionNumber
        self.sessionStartTime = Date()
        self.lastActivity = Date()
        startDurationTimer()
    }

    func updateState(_ newState: NotchiState) {
        state = newState
        lastActivity = Date()
    }

    func updateProcessingState(isProcessing: Bool) {
        self.isProcessing = isProcessing
        lastActivity = Date()
    }

    func recordUserPrompt(_ prompt: String) {
        let now = Date()
        lastUserPrompt = prompt.truncatedForPrompt()
        promptSubmitTime = now
        lastActivity = now
        logger.debug("Setting promptSubmitTime to: \(now)")
    }

    func updatePermissionMode(_ mode: String) {
        permissionMode = mode
    }

    func recordPreToolUse(tool: String?, toolInput: [String: Any]?, toolUseId: String?) {
        let description = SessionEvent.deriveDescription(tool: tool, toolInput: toolInput)
        let event = SessionEvent(
            timestamp: Date(),
            type: "PreToolUse",
            tool: tool,
            status: .running,
            toolInput: toolInput,
            toolUseId: toolUseId,
            description: description
        )
        recentEvents.append(event)
        trimEvents()
        lastActivity = Date()
    }

    func recordPostToolUse(tool: String?, toolUseId: String?, success: Bool) {
        if let toolUseId,
           let index = recentEvents.lastIndex(where: { $0.toolUseId == toolUseId && $0.status == .running }) {
            recentEvents[index].status = success ? .success : .error
        } else {
            let event = SessionEvent(
                timestamp: Date(),
                type: "PostToolUse",
                tool: tool,
                status: success ? .success : .error,
                toolInput: nil,
                toolUseId: toolUseId,
                description: nil
            )
            recentEvents.append(event)
            trimEvents()
        }
        lastActivity = Date()
    }

    func recordAssistantMessages(_ messages: [AssistantMessage]) {
        recentAssistantMessages.append(contentsOf: messages)
        while recentAssistantMessages.count > Self.maxAssistantMessages {
            recentAssistantMessages.removeFirst()
        }
        lastActivity = Date()
    }

    func clearAssistantMessages() {
        recentAssistantMessages = []
    }

    func endSession() {
        durationTimer?.cancel()
        durationTimer = nil
        isProcessing = false
    }

    private func trimEvents() {
        while recentEvents.count > Self.maxEvents {
            recentEvents.removeFirst()
        }
    }

    private func startDurationTimer() {
        durationTimer = Task {
            while !Task.isCancelled {
                updateFormattedDuration()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updateFormattedDuration() {
        let total = Int(Date().timeIntervalSince(sessionStartTime))
        let minutes = total / 60
        let seconds = total % 60
        formattedDuration = String(format: "%dm %02ds", minutes, seconds)
    }
}

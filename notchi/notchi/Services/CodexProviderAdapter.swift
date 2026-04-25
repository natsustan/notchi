import Foundation

struct CodexProviderAdapter: AgentProviderAdapter {
    nonisolated let provider: AgentProvider = .codex
    nonisolated init() {}

    // WHY: Adapter normalization can happen from multiple queues, and the
    // struct itself has no identity we can synchronize on. Track transcript-backed
    // Codex sessions behind a static lock instead.
    private static let transcriptBackedSessionLock = NSLock()
    private nonisolated(unsafe) static var transcriptBackedSessionIDs: Set<String> = []

    @discardableResult
    nonisolated func installIfNeeded() -> Bool {
        CodexHookInstaller.installIfNeeded()
    }

    nonisolated func isProviderAvailable() -> Bool {
        CodexHookInstaller.codexDirectoryExists()
    }

    nonisolated func isInstalled() -> Bool {
        CodexHookInstaller.isInstalled()
    }

    nonisolated func configureForLaunch() {}

    nonisolated func normalize(_ envelope: AgentHookEnvelope) -> HookEvent? {
        guard let event = NormalizedAgentEvent.codexEvent(named: envelope.event) else {
            return nil
        }

        if Self.shouldIgnoreUntrackableSessionEvent(envelope, event: event) {
            return nil
        }

        let prompt = Self.displayPrompt(
            from: envelope.userPrompt,
            hasAttachments: envelope.hasAttachments == true
        )

        return HookEvent(
            provider: provider,
            rawSessionId: envelope.sessionId,
            transcriptPath: envelope.transcriptPath,
            cwd: envelope.cwd,
            event: event,
            status: envelope.status,
            tool: envelope.tool,
            toolInput: envelope.toolInput,
            toolUseId: envelope.toolUseId,
            userPrompt: prompt.text,
            userPromptHasAttachments: prompt.hasAttachments,
            permissionMode: envelope.permissionMode,
            interactive: envelope.interactive ?? true,
            codexProcessId: envelope.codexProcessId,
            codexOrigin: envelope.codexOrigin
        )
    }

    private nonisolated static func shouldIgnoreUntrackableSessionEvent(
        _ envelope: AgentHookEnvelope,
        event: NormalizedAgentEvent
    ) -> Bool {
        transcriptBackedSessionLock.lock()
        defer { transcriptBackedSessionLock.unlock() }

        if hasTranscriptPath(envelope) {
            if event == .stop || event == .sessionEnded {
                transcriptBackedSessionIDs.remove(envelope.sessionId)
            } else {
                transcriptBackedSessionIDs.insert(envelope.sessionId)
            }
            return false
        }

        if transcriptBackedSessionIDs.contains(envelope.sessionId) {
            if event == .stop || event == .sessionEnded {
                transcriptBackedSessionIDs.remove(envelope.sessionId)
            }
            return false
        }

        return true
    }

    private nonisolated static func hasTranscriptPath(_ envelope: AgentHookEnvelope) -> Bool {
        !(envelope.transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private nonisolated static func displayPrompt(
        from rawPrompt: String?,
        hasAttachments: Bool
    ) -> (text: String?, hasAttachments: Bool) {
        let trimmedPrompt = rawPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasFilesPreamble = trimmedPrompt.hasPrefix("# Files mentioned by the user:")

        let request: String
        let lines = trimmedPrompt.components(separatedBy: .newlines)
        if hasFilesPreamble,
           let requestMarkerLineIndex = lines.firstIndex(where: {
               $0.trimmingCharacters(in: .whitespaces) == "## My request for Codex:"
           }) {
            request = lines.dropFirst(requestMarkerLineIndex + 1)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if hasFilesPreamble {
            request = ""
        } else {
            request = trimmedPrompt
        }

        return (
            text: request.isEmpty ? nil : request,
            hasAttachments: hasAttachments || hasFilesPreamble
        )
    }

    nonisolated static func resetTranscriptBackedSessionTrackingForTests() {
        transcriptBackedSessionLock.lock()
        defer { transcriptBackedSessionLock.unlock() }
        transcriptBackedSessionIDs.removeAll()
    }
}

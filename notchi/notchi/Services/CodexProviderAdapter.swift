import Foundation

struct CodexProviderAdapter: AgentProviderAdapter {
    nonisolated let provider: AgentProvider = .codex
    nonisolated init() {}

    // WHY: Adapter normalization can happen from multiple queues, and the
    // struct itself has no identity we can synchronize on. Track ignored
    // internal sidecar session IDs behind a static lock instead.
    private static let internalSessionLock = NSLock()
    private nonisolated(unsafe) static var internalSessionIDs: Set<String> = []

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

        if Self.shouldIgnoreInternalSessionEvent(envelope, event: event) {
            return nil
        }

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
            userPrompt: envelope.userPrompt,
            permissionMode: envelope.permissionMode,
            interactive: envelope.interactive ?? true
        )
    }

    private nonisolated static func shouldIgnoreInternalSessionEvent(
        _ envelope: AgentHookEnvelope,
        event: NormalizedAgentEvent
    ) -> Bool {
        internalSessionLock.lock()
        defer { internalSessionLock.unlock() }

        if internalSessionIDs.contains(envelope.sessionId) {
            if event == .stop || event == .sessionEnded {
                internalSessionIDs.remove(envelope.sessionId)
            }
            return true
        }

        if event == .userPromptSubmitted,
           isInternalDesktopTitleGenerator(envelope) {
            internalSessionIDs.insert(envelope.sessionId)
            return true
        }

        return false
    }

    private nonisolated static func isInternalDesktopTitleGenerator(_ envelope: AgentHookEnvelope) -> Bool {
        guard (envelope.transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              envelope.permissionMode == "bypassPermissions",
              let prompt = envelope.userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            return false
        }

        return prompt.hasPrefix("You are a helpful assistant.")
            && prompt.contains("provide a short title for a task")
            && prompt.contains("User prompt:")
    }

    nonisolated static func resetInternalSessionTrackingForTests() {
        internalSessionLock.lock()
        defer { internalSessionLock.unlock() }
        internalSessionIDs.removeAll()
    }
}

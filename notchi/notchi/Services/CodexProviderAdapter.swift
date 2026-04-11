import Foundation

struct CodexProviderAdapter: AgentProviderAdapter {
    nonisolated let provider: AgentProvider = .codex
    nonisolated init() {}

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

        return HookEvent(
            provider: provider,
            rawSessionId: envelope.sessionId,
            transcriptPath: envelope.transcriptPath,
            cwd: envelope.cwd,
            event: event,
            status: envelope.status,
            pid: envelope.pid,
            tty: envelope.tty,
            tool: envelope.tool,
            toolInput: envelope.toolInput,
            toolUseId: envelope.toolUseId,
            userPrompt: envelope.userPrompt,
            permissionMode: envelope.permissionMode,
            interactive: envelope.interactive ?? true,
            model: envelope.model
        )
    }
}

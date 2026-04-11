import Foundation

struct CodexProviderAdapter: AgentProviderAdapter {
    let provider: AgentProvider = .codex

    @discardableResult
    func installIfNeeded() -> Bool {
        CodexHookInstaller.installIfNeeded()
    }

    func isInstalled() -> Bool {
        CodexHookInstaller.isInstalled()
    }

    func configureForLaunch() {}

    func normalize(_ envelope: AgentHookEnvelope) -> HookEvent? {
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

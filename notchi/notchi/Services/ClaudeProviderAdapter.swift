import Foundation

struct ClaudeProviderAdapter: AgentProviderAdapter {
    let provider: AgentProvider = .claude

    @discardableResult
    func installIfNeeded() -> Bool {
        HookInstaller.installIfNeeded()
    }

    func isInstalled() -> Bool {
        HookInstaller.isInstalled()
    }

    func configureForLaunch() {
        let claudeConfig = ClaudeConfigDirectoryResolver.resolve()
        ConversationParser.configureClaudeProjectsRootPath(using: claudeConfig)
    }

    func normalize(_ envelope: AgentHookEnvelope) -> HookEvent? {
        guard let event = NormalizedAgentEvent.claudeEvent(named: envelope.event) else {
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
            interactive: envelope.interactive,
            model: envelope.model
        )
    }
}

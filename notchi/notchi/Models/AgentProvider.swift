import Foundation

nonisolated struct ProviderCapabilities: Sendable {
    let supportsPermissionPrompts: Bool
    let supportsUsageResumeTriggers: Bool
    let supportsPromptEmotionAnalysis: Bool
    let supportsDerivedTranscriptFallback: Bool
}

nonisolated enum AgentProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        }
    }

    var capabilities: ProviderCapabilities {
        switch self {
        case .claude:
            ProviderCapabilities(
                supportsPermissionPrompts: true,
                supportsUsageResumeTriggers: true,
                supportsPromptEmotionAnalysis: true,
                supportsDerivedTranscriptFallback: true
            )
        case .codex:
            ProviderCapabilities(
                supportsPermissionPrompts: true,
                supportsUsageResumeTriggers: false,
                supportsPromptEmotionAnalysis: false,
                supportsDerivedTranscriptFallback: false
            )
        }
    }
}

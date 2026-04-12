import Foundation

struct ProviderCapabilities: Sendable {
    let supportsPermissionPrompts: Bool
    let supportsUsageResumeTriggers: Bool
    let supportsPromptEmotionAnalysis: Bool
    let supportsDerivedTranscriptFallback: Bool
}

enum AgentProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case codex

    nonisolated var badgeText: String {
        switch self {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        }
    }

    nonisolated var capabilities: ProviderCapabilities {
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
                supportsPermissionPrompts: false,
                supportsUsageResumeTriggers: false,
                supportsPromptEmotionAnalysis: false,
                supportsDerivedTranscriptFallback: false
            )
        }
    }
}

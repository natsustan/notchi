import Foundation

struct ProviderCapabilities: Sendable {
    let supportsPermissionPrompts: Bool
    let supportsCompaction: Bool
    let supportsUsageResumeTriggers: Bool
    let supportsPromptEmotionAnalysis: Bool
    let supportsDerivedTranscriptFallback: Bool
    let supportsSessionEnd: Bool
}

enum AgentProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case codex

    nonisolated var displayName: String {
        switch self {
        case .claude:
            "Claude Code"
        case .codex:
            "Codex"
        }
    }

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
                supportsCompaction: true,
                supportsUsageResumeTriggers: true,
                supportsPromptEmotionAnalysis: true,
                supportsDerivedTranscriptFallback: true,
                supportsSessionEnd: true
            )
        case .codex:
            ProviderCapabilities(
                supportsPermissionPrompts: false,
                supportsCompaction: false,
                supportsUsageResumeTriggers: false,
                supportsPromptEmotionAnalysis: false,
                supportsDerivedTranscriptFallback: false,
                supportsSessionEnd: false
            )
        }
    }
}

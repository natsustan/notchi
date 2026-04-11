import Foundation

struct ProviderSessionKey: Hashable, Sendable {
    let provider: AgentProvider
    let rawSessionId: String

    nonisolated var stableId: String {
        "\(provider.rawValue):\(rawSessionId)"
    }
}

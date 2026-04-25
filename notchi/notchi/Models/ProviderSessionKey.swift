import Foundation

nonisolated struct ProviderSessionKey: Hashable, Sendable {
    let provider: AgentProvider
    let rawSessionId: String

    nonisolated init(provider: AgentProvider, rawSessionId: String) {
        self.provider = provider
        self.rawSessionId = rawSessionId
    }

    nonisolated init?(stableId: String) {
        guard let separatorIndex = stableId.firstIndex(of: ":") else { return nil }

        let providerRawValue = String(stableId[..<separatorIndex])
        let rawSessionId = String(stableId[stableId.index(after: separatorIndex)...])
        guard let provider = AgentProvider(rawValue: providerRawValue), !rawSessionId.isEmpty else { return nil }

        self.init(provider: provider, rawSessionId: rawSessionId)
    }

    nonisolated var stableId: String {
        "\(provider.rawValue):\(rawSessionId)"
    }
}

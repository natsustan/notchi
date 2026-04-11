import Foundation

nonisolated protocol AgentProviderAdapter: Sendable {
    nonisolated var provider: AgentProvider { get }

    @discardableResult
    nonisolated func installIfNeeded() -> Bool

    /// Returns whether the provider runtime itself is available on this machine,
    /// regardless of whether Notchi has installed hooks for it yet.
    nonisolated func isProviderAvailable() -> Bool
    nonisolated func isInstalled() -> Bool
    nonisolated func configureForLaunch()
    nonisolated func normalize(_ envelope: AgentHookEnvelope) -> HookEvent?
}

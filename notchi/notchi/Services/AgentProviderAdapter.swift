import Foundation

protocol AgentProviderAdapter {
    var provider: AgentProvider { get }

    @discardableResult
    func installIfNeeded() -> Bool

    func isInstalled() -> Bool
    func configureForLaunch()
    func normalize(_ envelope: AgentHookEnvelope) -> HookEvent?
}

import Foundation
import os.log

private let integrationLogger = Logger(subsystem: "com.ruban.notchi", category: "IntegrationCoordinator")

final class IntegrationCoordinator {
    static let shared = IntegrationCoordinator()

    private let socketServer: SocketServer
    private let adaptersByProvider: [AgentProvider: any AgentProviderAdapter]

    init(
        socketServer: SocketServer = .shared,
        adapters: [any AgentProviderAdapter] = [ClaudeProviderAdapter(), CodexProviderAdapter()]
    ) {
        self.socketServer = socketServer
        self.adaptersByProvider = Dictionary(uniqueKeysWithValues: adapters.map { ($0.provider, $0) })
    }

    func prepareForLaunch() {
        for provider in AgentProvider.allCases {
            adaptersByProvider[provider]?.configureForLaunch()
        }
    }

    func installHooksIfNeeded() {
        for provider in AgentProvider.allCases {
            _ = adaptersByProvider[provider]?.installIfNeeded()
        }
    }

    @discardableResult
    func installHooksIfNeeded(for provider: AgentProvider) -> Bool {
        adaptersByProvider[provider]?.installIfNeeded() ?? false
    }

    func isInstalled(for provider: AgentProvider) -> Bool {
        adaptersByProvider[provider]?.isInstalled() ?? false
    }

    func hasAnyInstalledHooks() -> Bool {
        AgentProvider.allCases.contains { isInstalled(for: $0) }
    }

    func start(onEvent: @escaping @MainActor (HookEvent) -> Void) {
        socketServer.start { [weak self] envelope in
            guard let self else { return }
            guard let event = self.normalize(envelope) else {
                integrationLogger.warning(
                    "Dropped unsupported \(envelope.provider.rawValue, privacy: .public) hook event: \(envelope.event, privacy: .public)"
                )
                return
            }

            Task { @MainActor in
                onEvent(event)
            }
        }
    }

    func stop() {
        socketServer.stop()
    }

    private func normalize(_ envelope: AgentHookEnvelope) -> HookEvent? {
        adaptersByProvider[envelope.provider]?.normalize(envelope)
    }
}

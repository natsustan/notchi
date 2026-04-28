import ServiceManagement
import SwiftUI

private enum HookInstallBadgeState {
    case installed
    case notInstalled
    case providerMissing
    case error

    func text(for provider: AgentProvider) -> String {
        switch self {
        case .installed:
            "Installed"
        case .notInstalled:
            "Not Installed"
        case .providerMissing:
            "\(provider.displayName) Missing"
        case .error:
            "Error"
        }
    }

    var color: Color {
        switch self {
        case .installed:
            TerminalColors.green
        case .providerMissing:
            TerminalColors.amber
        case .notInstalled, .error:
            TerminalColors.red
        }
    }
}

struct PanelSettingsView: View {
    @Binding private var showingEmotionAnalysisSettings: Bool
    @AppStorage(AppSettings.hideSpriteWhenIdleKey) private var hideSpriteWhenIdle = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var claudeHooksInstalled = IntegrationCoordinator.shared.isInstalled(for: .claude)
    @State private var claudeHooksError = false
    @State private var codexHooksInstalled = IntegrationCoordinator.shared.isInstalled(for: .codex)
    @State private var codexHooksError = false
    @ObservedObject private var updateManager = UpdateManager.shared
    private var usageConnected: Bool { ClaudeUsageService.shared.isConnected }

    init(showingEmotionAnalysisSettings: Binding<Bool> = .constant(false)) {
        _showingEmotionAnalysisSettings = showingEmotionAnalysisSettings
    }

    var body: some View {
        ZStack {
            if !showingEmotionAnalysisSettings {
                mainSettings
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }

            if showingEmotionAnalysisSettings {
                EmotionAnalysisSettingsView()
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingEmotionAnalysisSettings)
        .padding(.horizontal, SettingsLayout.panelHorizontalPadding)
        .padding(.top, SettingsLayout.topPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var mainSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    systemSection
                    Divider().background(Color.white.opacity(0.08))
                    aiSection
                    Divider().background(Color.white.opacity(0.08))
                    aboutSection
                }
                .padding(.top, SettingsLayout.topPadding)
            }
            .scrollIndicators(.hidden)

            Spacer()

            quitSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            ScreenPickerRow(screenSelector: ScreenSelector.shared)

            SoundPickerView()

            Button(action: toggleLaunchAtLogin) {
                SettingsRowView(icon: "power", title: "Launch at Login") {
                    ToggleSwitch(isOn: launchAtLogin)
                }
            }
            .buttonStyle(.plain)

            Button(action: toggleHideSpriteWhenIdle) {
                SettingsRowView(icon: "pip.exit", title: "Hide Sprite When Idle") {
                    ToggleSwitch(isOn: hideSpriteWhenIdle)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Button(action: { installHooksIfNeeded(for: .claude) }) {
                SettingsRowView(icon: "terminal", title: "Claude Hooks") {
                    statusBadge(
                        hookStatusText(for: .claude, installed: claudeHooksInstalled, error: claudeHooksError),
                        color: hookStatusColor(for: .claude, installed: claudeHooksInstalled, error: claudeHooksError)
                    )
                }
            }
            .buttonStyle(.plain)

            Button(action: { installHooksIfNeeded(for: .codex) }) {
                SettingsRowView(icon: "terminal", title: "Codex Hooks") {
                    statusBadge(
                        hookStatusText(for: .codex, installed: codexHooksInstalled, error: codexHooksError),
                        color: hookStatusColor(for: .codex, installed: codexHooksInstalled, error: codexHooksError)
                    )
                }
            }
            .buttonStyle(.plain)

            Button(action: connectUsage) {
                SettingsRowView(icon: "gauge.with.dots.needle.33percent", title: "Claude Usage") {
                    statusBadge(
                        usageConnected ? "Connected" : "Not Connected",
                        color: usageConnected ? TerminalColors.green : TerminalColors.red
                    )
                }
            }
            .buttonStyle(.plain)

            emotionAnalysisRow
        }
    }

    private var emotionAnalysisRow: some View {
        Button(action: { showingEmotionAnalysisSettings = true }) {
            SettingsRowView(icon: "brain", title: "Emotion Analysis") {
                HStack(spacing: 6) {
                    let status = emotionAnalysisStatus()
                    statusBadge(status.text, color: status.color)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Button(action: handleUpdatesAction) {
                SettingsRowView(icon: "arrow.triangle.2.circlepath", title: "Check for Updates") {
                    updateStatusView
                }
            }
            .buttonStyle(.plain)

            Button(action: openGitHubRepo) {
                SettingsRowView(icon: "star", title: "Star on GitHub") {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func openGitHubRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sk-ruban/notchi")!)
    }

    private func openLatestReleasePage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sk-ruban/notchi/releases/latest")!)
    }

    private var quitSection: some View {
        Button(action: {
            NSApplication.shared.terminate(nil)
        }) {
            HStack {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13))
                Text("Quit Notchi")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(TerminalColors.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, SettingsLayout.quitButtonVerticalPadding)
            .padding(.horizontal, SettingsLayout.quitButtonHorizontalPadding)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(TerminalColors.red.opacity(0.1))
                    .padding(.horizontal, -SettingsLayout.quitButtonHorizontalPadding)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }

    private func connectUsage() {
        ClaudeUsageService.shared.connectAndStartPolling()
    }

    private func toggleHideSpriteWhenIdle() {
        hideSpriteWhenIdle.toggle()
    }

    private func handleUpdatesAction() {
        if case .upToDate = updateManager.state {
            openLatestReleasePage()
        } else {
            updateManager.checkForUpdates()
        }
    }

    private func hookStatusText(for provider: AgentProvider, installed: Bool, error: Bool) -> String {
        hookStatus(for: provider, installed: installed, error: error).text(for: provider)
    }

    private func hookStatusColor(for provider: AgentProvider, installed: Bool, error: Bool) -> Color {
        hookStatus(for: provider, installed: installed, error: error).color
    }

    private func hookStatus(for provider: AgentProvider, installed: Bool, error: Bool) -> HookInstallBadgeState {
        guard IntegrationCoordinator.shared.isProviderAvailable(for: provider) else {
            return .providerMissing
        }
        if error { return .error }
        if installed { return .installed }
        return .notInstalled
    }

    private func installHooksIfNeeded(for provider: AgentProvider) {
        switch provider {
        case .claude:
            guard !claudeHooksInstalled else { return }
            claudeHooksError = false
        case .codex:
            guard !codexHooksInstalled else { return }
            codexHooksError = false
        }

        guard IntegrationCoordinator.shared.isProviderAvailable(for: provider) else {
            switch provider {
            case .claude:
                claudeHooksInstalled = false
                claudeHooksError = false
            case .codex:
                codexHooksInstalled = false
                codexHooksError = false
            }
            return
        }

        let success = IntegrationCoordinator.shared.installHooksIfNeeded(for: provider)
        let installed = IntegrationCoordinator.shared.isInstalled(for: provider)

        switch provider {
        case .claude:
            claudeHooksInstalled = installed
            claudeHooksError = !success || !installed
        case .codex:
            codexHooksInstalled = installed
            codexHooksError = !success || !installed
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
            .frame(maxWidth: 160, alignment: .trailing)
    }

    private func emotionAnalysisStatus() -> (text: String, color: Color) {
        let provider = AppSettings.emotionAnalysisProvider
        if hasStoredApiKey(for: provider) {
            return (provider.displayName, TerminalColors.green)
        }

        if provider == .claude,
           ClaudeSettingsConfig.existsAtDefaultLocation() {
            return ("Claude Code", TerminalColors.green)
        }

        return ("No Key", TerminalColors.red)
    }

    private func hasStoredApiKey(for provider: EmotionAnalysisProvider) -> Bool {
        AppSettings.apiKey(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateManager.state {
        case .checking:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking...")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.dimmedText)
            }
        case .upToDate:
            statusBadge("Up to date", color: TerminalColors.green)
        case .updateAvailable:
            statusBadge("Update available", color: TerminalColors.amber)
        case .downloading:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Downloading...")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.dimmedText)
            }
        case .readyToInstall:
            statusBadge("Ready to install", color: TerminalColors.green)
        case .error(let failure):
            statusBadge(failure.label, color: TerminalColors.red)
        case .idle:
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.system(size: 10))
                .foregroundColor(TerminalColors.dimmedText)
        }
    }
}

private struct EmotionAnalysisSettingsView: View {
    @State private var provider = AppSettings.emotionAnalysisProvider
    @State private var model = AppSettings.selectedEmotionAnalysisModel(for: AppSettings.emotionAnalysisProvider)
    @State private var apiKeyInput = AppSettings.apiKey(for: AppSettings.emotionAnalysisProvider) ?? ""
    @State private var isProviderPickerExpanded = false
    @State private var isModelPickerExpanded = false

    private var hasApiKey: Bool {
        !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    providerSection
                    modelSection
                    apiKeySection
                }
                .padding(.top, SettingsLayout.topPadding)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear {
            saveApiKey(for: provider)
        }
        .animation(.spring(response: 0.3), value: isProviderPickerExpanded)
        .animation(.spring(response: 0.3), value: isModelPickerExpanded)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { isProviderPickerExpanded.toggle() }) {
                SettingsRowView(icon: "switch.2", title: "Provider") {
                    HStack(spacing: 4) {
                        Text(provider.displayName)
                            .font(.system(size: 11))
                            .foregroundColor(TerminalColors.secondaryText)
                        Image(systemName: isProviderPickerExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                }
            }
            .buttonStyle(.plain)

            if isProviderPickerExpanded {
                providerPicker
            }
        }
    }

    private var providerPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(EmotionAnalysisProvider.allCases) { option in
                    providerRow(option)
                }
            }
            .padding(.vertical, SettingsLayout.pickerInset)
        }
        .frame(height: pickerHeight(optionCount: EmotionAnalysisProvider.allCases.count))
        .background(TerminalColors.subtleBackground)
        .cornerRadius(8)
        .padding(.top, SettingsLayout.pickerInset)
    }

    private func providerRow(_ option: EmotionAnalysisProvider) -> some View {
        Button(action: { selectProvider(option) }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(provider == option ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)

                Text(option.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(provider == option ? TerminalColors.primaryText : TerminalColors.secondaryText)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(provider == option ? TerminalColors.hoverBackground : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.apiKeySpacing) {
            SettingsRowView(icon: "key", title: "API Key") {
                statusBadge(hasApiKey ? "Saved" : fallbackStatusText, color: hasApiKey ? TerminalColors.green : fallbackStatusColor)
            }

            HStack(spacing: 6) {
                SecureField("", text: $apiKeyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(TerminalColors.primaryText)
                    .padding(.horizontal, SettingsLayout.fieldHorizontalPadding)
                    .padding(.vertical, SettingsLayout.fieldVerticalPadding)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
                    .onSubmit { saveApiKey(for: provider) }
                    .overlay(alignment: .leading) {
                        if apiKeyInput.isEmpty {
                            Text(provider.apiKeyPlaceholder)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(TerminalColors.dimmedText)
                                .padding(.leading, SettingsLayout.fieldHorizontalPadding)
                                .allowsHitTesting(false)
                        }
                    }

                Button(action: { saveApiKey(for: provider) }) {
                    Image(systemName: hasApiKey ? "checkmark.circle.fill" : "arrow.right.circle")
                        .font(.system(size: 14))
                        .foregroundColor(hasApiKey ? TerminalColors.green : TerminalColors.dimmedText)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, SettingsLayout.fieldLeadingInset)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { isModelPickerExpanded.toggle() }) {
                SettingsRowView(icon: "cpu", title: "Model") {
                    HStack(spacing: 4) {
                        Text(model.displayName)
                            .font(.system(size: 11))
                            .foregroundColor(TerminalColors.secondaryText)
                        Image(systemName: isModelPickerExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(TerminalColors.dimmedText)
                    }
                }
            }
            .buttonStyle(.plain)

            if isModelPickerExpanded {
                modelPicker
            }
        }
    }

    private var modelPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(EmotionAnalysisModel.models(for: provider)) { option in
                    modelRow(option)
                }
            }
            .padding(.vertical, SettingsLayout.pickerInset)
        }
        .frame(height: pickerHeight(optionCount: EmotionAnalysisModel.models(for: provider).count))
        .background(TerminalColors.subtleBackground)
        .cornerRadius(8)
        .padding(.top, SettingsLayout.pickerInset)
    }

    private func modelRow(_ option: EmotionAnalysisModel) -> some View {
        Button(action: { selectModel(option) }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model == option ? TerminalColors.green : Color.clear)
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(model == option ? TerminalColors.primaryText : TerminalColors.secondaryText)
                    Text(option.detail)
                        .font(.system(size: 9))
                        .foregroundColor(TerminalColors.dimmedText)
                }

                Spacer()
            }
            .padding(.horizontal, SettingsLayout.pickerOptionHorizontalPadding)
            .padding(.vertical, SettingsLayout.pickerOptionVerticalPadding)
            .background(model == option ? TerminalColors.hoverBackground : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickerHeight(optionCount: Int) -> CGFloat {
        let rowHeight: CGFloat = 28
        let rowSpacing: CGFloat = 4
        let visibleCount = min(optionCount, 6)
        return CGFloat(visibleCount) * rowHeight + CGFloat(max(visibleCount - 1, 0)) * rowSpacing
    }

    private var fallbackStatusText: String {
        if provider == .claude, hasClaudeCodeFallback {
            return "Claude Code"
        }
        return "Missing"
    }

    private var fallbackStatusColor: Color {
        provider == .claude && hasClaudeCodeFallback ? TerminalColors.green : TerminalColors.red
    }

    private var hasClaudeCodeFallback: Bool {
        ClaudeSettingsConfig.existsAtDefaultLocation()
    }

    private func selectProvider(_ newProvider: EmotionAnalysisProvider) {
        guard newProvider != provider else { return }
        saveApiKey(for: provider)
        provider = newProvider
        AppSettings.emotionAnalysisProvider = newProvider
        model = AppSettings.selectedEmotionAnalysisModel(for: newProvider)
        apiKeyInput = AppSettings.apiKey(for: newProvider) ?? ""
    }

    private func selectModel(_ newModel: EmotionAnalysisModel) {
        model = newModel
        AppSettings.setEmotionAnalysisModel(newModel, for: provider)
    }

    private func saveApiKey(for provider: EmotionAnalysisProvider) {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.setApiKey(trimmed.isEmpty ? nil : trimmed, for: provider)
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
            .frame(maxWidth: 160, alignment: .trailing)
    }
}

struct SettingsRowView<Trailing: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.secondaryText)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.primaryText)

            Spacer()

            trailing()
        }
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
        .contentShape(Rectangle())
    }
}

struct ToggleSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? TerminalColors.green : Color.white.opacity(0.15))
                .frame(width: 32, height: 18)

            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

#Preview {
    PanelSettingsView()
        .frame(width: 402, height: 400)
        .background(Color.black)
}

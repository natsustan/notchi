import SwiftUI

struct UsageDetailView: View {
    let claudeUsage: ClaudeUsageService
    let codexUsage: CodexUsageService
    let costStore: CostHistoryStore
    let defaultProvider: AgentProvider

    @State private var selectedProvider: AgentProvider

    init(
        claudeUsage: ClaudeUsageService,
        codexUsage: CodexUsageService,
        costStore: CostHistoryStore,
        defaultProvider: AgentProvider
    ) {
        self.claudeUsage = claudeUsage
        self.codexUsage = codexUsage
        self.costStore = costStore
        self.defaultProvider = defaultProvider
        _selectedProvider = State(initialValue: defaultProvider)
    }

    private var claudeHasData: Bool {
        UsageMetrics.claudeHasData(
            usage: claudeUsage.currentUsage,
            weeklyUsage: claudeUsage.currentWeeklyUsage,
            sonnetUsage: claudeUsage.currentSonnetUsage,
            extraUsage: claudeUsage.currentExtraUsage
        )
    }

    private var codexHasData: Bool {
        UsageMetrics.codexHasData(
            usage: codexUsage.currentUsage,
            weeklyUsage: codexUsage.currentWeeklyUsage
        )
    }

    private var showsToggle: Bool {
        claudeHasData && codexHasData
    }

    private var resolvedProvider: AgentProvider {
        switch selectedProvider {
        case .claude where !claudeHasData && codexHasData: return .codex
        case .codex where !codexHasData && claudeHasData: return .claude
        default: return selectedProvider
        }
    }

    private var periods: [UsagePeriodDisplay] {
        switch resolvedProvider {
        case .claude:
            let stale = claudeUsage.isUsageStale
            let heldOver = stale || claudeUsage.isUsingHeadersFallback
            return [
                UsageMetrics.periodDisplay(title: "Session", usage: claudeUsage.currentUsage, isStale: stale),
                UsageMetrics.periodDisplay(title: "Weekly", usage: claudeUsage.currentWeeklyUsage, isStale: heldOver),
                UsageMetrics.periodDisplay(title: "Sonnet", usage: claudeUsage.currentSonnetUsage, isStale: heldOver),
            ].compactMap { $0 }
        case .codex:
            let stale = codexUsage.isUsageStale
            return [
                UsageMetrics.periodDisplay(title: "Session", usage: codexUsage.currentUsage, isStale: stale),
                UsageMetrics.periodDisplay(title: "Weekly", usage: codexUsage.currentWeeklyUsage, isStale: stale),
                UsageMetrics.periodDisplay(title: "Reviews", usage: codexUsage.currentReviewsUsage, isStale: stale),
            ].compactMap { $0 }
        }
    }

    private var codexCreditsUSD: Double? {
        resolvedProvider == .codex ? codexUsage.currentExtraCreditsUSD : nil
    }

    private var extraUsage: ExtraUsageDisplay? {
        resolvedProvider == .claude
            ? UsageMetrics.extraUsageDisplay(claudeUsage.currentExtraUsage)
            : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch resolvedProvider {
            case .claude:
                CostDashboardView(store: costStore)
            case .codex:
                Text("Cost history coming soon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().background(Color.white.opacity(0.08))

            ForEach(periods, id: \.title) { period in
                UsagePeriodRowView(display: period)
            }

            if let extraUsage {
                ExtraUsageRowView(display: extraUsage)
            }

            if let codexCreditsUSD {
                CodexCreditsRowView(remainingUSD: codexCreditsUSD)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if showsToggle {
                providerToggle
            } else {
                Text(resolvedProvider.displayName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(TerminalColors.primaryText)
            }

            Spacer()
        }
    }

    private var providerToggle: some View {
        HStack(spacing: 4) {
            ForEach([AgentProvider.claude, .codex], id: \.self) { provider in
                Button(action: { selectedProvider = provider }) {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(
                            resolvedProvider == provider
                                ? TerminalColors.primaryText
                                : TerminalColors.dimmedText
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(resolvedProvider == provider ? TerminalColors.hoverBackground : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct UsageProgressBar: View {
    let percentUsed: Int
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(TerminalColors.subtleBackground)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geometry.size.width * Double(min(max(percentUsed, 0), 100)) / 100)
            }
        }
        .frame(height: 6)
    }
}

struct UsagePeriodRowView: View {
    let display: UsagePeriodDisplay

    var body: some View {
        let color = display.isStale
            ? TerminalColors.dimmedText
            : TerminalColors.usageColor(forPercentUsed: display.percentUsed)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(display.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(TerminalColors.primaryText)
                if display.isStale {
                    Text("stale data")
                        .font(.system(size: 11))
                        .foregroundColor(TerminalColors.secondaryText)
                } else if let resetText = display.resetText {
                    Text(resetText)
                        .font(.system(size: 11))
                        .foregroundColor(TerminalColors.secondaryText)
                }
                Spacer()
                Text("\(display.percentUsed)%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
            }
            UsageProgressBar(percentUsed: display.percentUsed, color: color)
        }
    }
}

struct ExtraUsageRowView: View {
    let display: ExtraUsageDisplay

    var body: some View {
        let color = TerminalColors.usageColor(forPercentUsed: display.percentUsed)
        VStack(alignment: .leading, spacing: 7) {
            Text("Extra usage")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TerminalColors.primaryText)
            UsageProgressBar(percentUsed: display.percentUsed, color: color)
            HStack {
                Text("\(Self.currency(display.usedCredits)) used")
                    .foregroundColor(TerminalColors.secondaryText)
                Spacer()
                Text("\(Self.currency(display.monthlyLimit)) limit")
                    .foregroundColor(TerminalColors.secondaryText)
            }
            .font(.system(size: 11))
        }
    }

    static func currency(_ value: Double) -> String {
        if value == value.rounded() {
            return "$\(Int(value))"
        }
        return String(format: "$%.2f", value)
    }
}

struct CodexCreditsRowView: View {
    let remainingUSD: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Extra usage")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TerminalColors.primaryText)
            HStack {
                Text(String(format: "$%.2f remaining", remainingUSD))
                    .foregroundColor(TerminalColors.secondaryText)
                Spacer()
            }
            .font(.system(size: 11))
        }
    }
}

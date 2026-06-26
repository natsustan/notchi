import Charts
import SwiftUI

enum CostStatFormatter {
    private static let usdFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        f.currencyCode = "USD"
        f.currencySymbol = "$"
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...:
            let v = Double(n) / 1_000_000_000
            return "\(formatted(v))B"
        case 1_000_000...:
            let v = Double(n) / 1_000_000
            return "\(formatted(v))M"
        case 1_000...:
            let v = Double(n) / 1_000
            return "\(formatted(v))K"
        default:
            return "\(n)"
        }
    }

    static func usd(_ amount: Double) -> String {
        usdFormatter.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }

    private static func formatted(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(v))
            : String(format: "%.1f", v)
    }

    static func modelName(_ raw: String) -> String {
        var s = raw
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if s.lowercased().hasPrefix("gpt") { return "GPT" + s.dropFirst(3) }
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        let parts = s.split(separator: "-").map(String.init)
        guard let family = parts.first, !family.isEmpty else { return raw }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? name : "\(name) \(version)"
    }
}

@MainActor
struct CostDashboardView: View {
    let store: CostHistoryStore

    @State private var selected: DailyCostReport.DayEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let report = store.report {
                statsRow(report)
                hoverDetail(report)
                chart(report)
                if report.entries.contains(where: { $0.requestCount > 0 && $0.pricedFraction < 1 }) {
                    Text("Some models lack pricing — cost is partial")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else if store.isScanning {
                ProgressView("Scanning usage…").font(.caption)
            } else {
                Text("No cost history yet").font(.caption).foregroundStyle(TerminalColors.dimmedText)
            }
        }
    }

    @ViewBuilder private func statsRow(_ r: DailyCostReport) -> some View {
        HStack(alignment: .top, spacing: 12) {
            stat("Today", CostStatFormatter.usd(r.todayCostUSD))
            stat("30d cost", CostStatFormatter.usd(r.windowCostUSD))
            stat("30d tokens", CostStatFormatter.tokens(r.windowTokens))
            stat("Latest tokens", CostStatFormatter.tokens(r.latestTokens))
            stat("Top model", r.topModel.map(CostStatFormatter.modelName) ?? "—")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(TerminalColors.dimmedText)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TerminalColors.primaryText)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func hoverDetail(_ r: DailyCostReport) -> some View {
        Text(selected.map { s in
            "\(Self.dayFormatter.string(from: s.date)) · "
                + "\(CostStatFormatter.usd(s.costUSD)) · "
                + "\(CostStatFormatter.tokens(s.totalTokens)) tok"
        } ?? " ")
        .font(.caption2)
        .foregroundStyle(TerminalColors.primaryText)
        .lineLimit(1)
    }

    private static let claudeBar = Color(red: 0.85, green: 0.49, blue: 0.26)
    private static let claudePeak = Color(red: 0.97, green: 0.62, blue: 0.32)
    private static let codexBar = Color(red: 0.18, green: 0.64, blue: 0.52)
    private static let codexPeak = Color(red: 0.30, green: 0.80, blue: 0.66)

    private func accent(_ provider: CostProvider) -> Color { provider == .codex ? Self.codexBar : Self.claudeBar }
    private func peak(_ provider: CostProvider) -> Color { provider == .codex ? Self.codexPeak : Self.claudePeak }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private func barColor(for e: DailyCostReport.DayEntry, maxCost: Double, provider: CostProvider) -> Color {
        if let s = selected, s.id == e.id { return peak(provider) }
        if e.costUSD >= maxCost && maxCost > 0 { return peak(provider) }
        return accent(provider)
    }

    private func nearest(to date: Date, in entries: [DailyCostReport.DayEntry]) -> DailyCostReport.DayEntry? {
        entries.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
    }

    @ViewBuilder private func chart(_ r: DailyCostReport) -> some View {
        let maxCost = r.entries.map(\.costUSD).max() ?? 0
        Chart(r.entries) { e in
            BarMark(x: .value("Day", e.date, unit: .day), y: .value("Cost", e.costUSD))
                .foregroundStyle(barColor(for: e, maxCost: maxCost, provider: r.provider))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 90)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let x = location.x - geo[plotFrame].origin.x
                            if let date: Date = proxy.value(atX: x) {
                                selected = nearest(to: date, in: r.entries)
                            }
                        case .ended:
                            selected = nil
                        }
                    }
            }
        }
    }
}

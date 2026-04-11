import SwiftUI

struct ProviderBadgeView: View {
    let provider: AgentProvider

    var body: some View {
        Text(provider.badgeText)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(provider.accentColor)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(provider.accentColor.opacity(0.16))
            .cornerRadius(4)
    }
}

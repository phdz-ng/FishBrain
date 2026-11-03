import SwiftUI

/// A card's status in the list: a small capsule colored by how it is getting on.
struct CardStatusChip: View {
    var status: CardStatus

    @Environment(\.accentChoice) private var accent

    private var colors: (text: Token, fill: Token) {
        switch status.tone {
        case .neutral: (Theme.TextColor.cardBack, Theme.Surface.control)
        case .learning: (Theme.Status.learning, Theme.Status.learning.with(opacity: 0.18))
        case .due: (accent.light, accent.flippedSurface)
        case .mastered: (Theme.Status.ok, Theme.Status.ok.with(opacity: 0.16))
        }
    }

    var body: some View {
        Text(status.text)
            .font(Theme.Typography.sectionLabel)
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(colors.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(colors.fill))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.accessibilityText)
    }
}

#if DEBUG
#Preview("Card status") {
    VStack(alignment: .leading, spacing: 8) {
        CardStatusChip(status: .new)
        CardStatusChip(status: .learning(600))
        CardStatusChip(status: .dueNow)
        CardStatusChip(status: .upcoming(4 * ReviewScheduler.day))
        CardStatusChip(status: .mastered(90 * ReviewScheduler.day))
    }
    .appearancePreview()
}
#endif

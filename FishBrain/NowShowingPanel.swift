import SwiftUI

/// Square preview, styled like the widget, of the card the widgets and notch show right now, with the
/// four grade buttons under it and today's count below. Ticks every second so the progress bar and
/// countdown stay live.
struct NowShowingPanel: View {
    /// Wide enough for four grade buttons ("Again" over "1 min") side by side.
    static let side: CGFloat = 280
    /// Everything but the card: the label, the four buttons, the countdown row and today's line, and
    /// the gaps between them.
    static let chromeHeight: CGFloat = 172
    static let minimumCardHeight: CGFloat = 150

    /// The card keeps its square when there is room and gives up height, down to a floor, when the
    /// window is short, so the buttons under it stay in view.
    static func cardHeight(available: CGFloat) -> CGFloat {
        min(side, max(minimumCardHeight, available - chromeHeight))
    }

    var deck: Deck
    var state: PlaybackState
    var onFlip: () -> Void
    var onSkip: () -> Void
    var onGrade: (ReviewGrade) -> Void = { _ in }
    /// Today's count and streak for a given moment; nil leaves the line out.
    var studySummary: (Date) -> StudySummary? = { _ in nil }
    /// Square unless the window is short; see `cardHeight(available:)`.
    var cardHeight: CGFloat = NowShowingPanel.side

    @Environment(\.accentChoice) private var accent

    /// Ticking on whole seconds keeps the countdown from flipping at odd sub-second moments.
    private static var nextWholeSecond: Date {
        Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.up))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Now showing")
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.TextColor.secondary)

            TimelineView(.periodic(from: Self.nextWholeSecond, by: 1)) { context in
                let showing = NowShowing.make(deck: deck, state: state, at: context.date)
                VStack(alignment: .leading, spacing: 12) {
                    card(showing)
                    grading(showing)
                    caption(showing)
                    if let summary = studySummary(context.date) { studyLine(summary) }
                }
            }
        }
        .frame(width: Self.side, alignment: .leading)
    }

    /// A card has to be turned over to be graded.
    static func canGrade(_ showing: NowShowing?) -> Bool { showing?.isFlipped == true }

    /// Always there, so the panel doesn't change height when the card turns over: dimmed and disabled
    /// while the front is showing. No bare 1 to 4 keys here; they would fight with typing in the list.
    private func grading(_ showing: NowShowing?) -> some View {
        GradeButtons(
            intervals: showing?.gradeIntervals ?? .forNewCard,
            size: .roomy,
            usesShortcuts: false,
            onGrade: onGrade
        )
        .disabled(!Self.canGrade(showing))
    }

    private func studyLine(_ summary: StudySummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill")
                .foregroundStyle(Theme.Streak.flame)
                .accessibilityHidden(true)
            Text(summary.openLine)
                .monospacedDigit()
                .accessibilityLabel(summary.accessibilityText)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.TextColor.cardBack)
    }

    private func card(_ showing: NowShowing?) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.widget, style: .continuous)
        return VStack(spacing: 0) {
            if let showing {
                HStack {
                    Text(showing.deckName).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(showing.positionText).monospacedDigit()
                }
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.meta(isFlipped: showing.isFlipped))
                CardFace(
                    text: showing.isFlipped ? showing.card.back : showing.card.front, isBack: showing.isFlipped, size: .small,
                    image: showing.isFlipped ? showing.card.backImage : showing.card.frontImage
                )
                CountdownProgressBar(progress: showing.progress)
            } else {
                Text("Add a card to see it here")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .frame(width: Self.side, height: cardHeight)
        .background(shape.fill(showing?.isFlipped == true ? accent.flippedSurface : Theme.Surface.widget))
        .overlay { shape.strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
        .contentShape(shape)
        .onTapGesture(perform: onFlip)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Flips the card")
    }

    private func caption(_ showing: NowShowing?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if let showing {
                Text("Next card in \(showing.countdownText)")
                    .monospacedDigit()
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer(minLength: 8)
            Button("Skip", action: onSkip)
                .buttonStyle(.capsuleSecondary)
                .disabled(showing == nil)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.TextColor.secondary)
    }
}

#if DEBUG
#Preview("Now showing") {
    HStack(alignment: .top, spacing: 24) {
        NowShowingPanel(
            deck: PreviewData.decks[0], state: PlaybackState(), onFlip: {}, onSkip: {}, studySummary: { _ in .sample }
        )
        NowShowingPanel(deck: Deck(name: "Empty"), state: PlaybackState(), onFlip: {}, onSkip: {})
    }
    .padding(24)
    .background(Theme.Surface.previewBackdrop)
    .preferredColorScheme(.dark)
}
#endif

import SwiftUI

/// What the resting notch shows, for each pill style. Used by the notch itself and by the preview
/// in Settings, so the preview is the real thing.
struct PillRestContent: View {
    var style: PillStyle
    var showing: NowShowing
    /// True on a real notch: the camera sits in the middle, so the content goes either side of it.
    var hasCamera: Bool
    /// The camera's width, the gap kept in the middle.
    var notchWidth: CGFloat
    /// When the card next changes; the fish swims toward it.
    var nextRotation = Date()
    /// False while the notch is open or hidden, so styles that animate stop redrawing.
    var isActive = true
    /// Today's count, the goal and the streak, for the streak style.
    var study: StudySummary?
    /// The study session, for the session style (and while one runs, whatever the style).
    var session: SessionPhase = .idle
    var lastSession: StudySession.Result?
    /// How long a card lasts: 5 minutes, or 30 seconds in a session.
    var rotationInterval = CardScheduler.defaultInterval
    /// An offer to make a card from a copy, or the note that one was made. Takes over the pill while it shows.
    var banner: CopyBanner?
    /// For the Card style: where the text goes, how often it flips, and when the front showed.
    var cardLayout: CardRestLayout = .drawn
    var flipInterval: NotchFlipInterval = .default
    var restStartedAt = Date()

    @Environment(\.accentChoice) private var accent

    var body: some View {
        if let banner {
            bannerContent(banner)
        } else if hasCamera && style == .card {
            cardContent
        } else if hasCamera {
            // Beside a camera there is room for Classic or the card text only.
            HStack(spacing: 0) {
                DeckIcon(color: showing.deckColor, size: 16)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0).frame(width: notchWidth)
                Self.positionLabel(showing)
                    .frame(maxWidth: .infinity)
            }
        } else {
            drawnContent
        }
    }

    /// On a real notch there is only the strip beside the camera, so a chip says what the pill is for;
    /// a drawn pill has room for what was copied.
    @ViewBuilder
    private func bannerContent(_ banner: CopyBanner) -> some View {
        if hasCamera {
            HStack(spacing: 0) {
                DeckIcon(color: showing.deckColor, size: 16)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0).frame(width: notchWidth)
                chip(banner.isOffer ? "+ Card" : "✓ Added")
                    .frame(maxWidth: .infinity)
            }
        } else {
            switch banner.kind {
            case .offer:
                HStack(spacing: 8) {
                    Text(banner.offerLabel)
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    chip("+ Make a card")
                }
                .padding(.horizontal, 10)
            case .added(let deckName):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(accent.light)
                        .accessibilityHidden(true)
                    Text("Added to \(deckName)")
                        .font(Theme.Typography.micro.weight(.semibold))
                        .foregroundStyle(Theme.TextColor.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.micro.weight(.semibold))
            .foregroundStyle(Theme.TextColor.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 7)
            .frame(height: 16)
            .background(Capsule().fill(accent.fill.with(opacity: 0.6)))
    }

    @ViewBuilder
    private var drawnContent: some View {
        switch PillStyle.resolved(style) {
        case .card:
            cardContent
        case .fish:
            FishPillContent(showing: showing, nextRotation: nextRotation, interval: rotationInterval, isActive: isActive)
        case .streak where study != nil:
            StreakPillContent(study: study!)
        case .session:
            SessionPillContent(phase: session, last: lastSession, isActive: isActive)
        case .classic, .streak:
            // Streak falls back to Classic until the notch has a study summary.
            HStack(spacing: 8) {
                DeckIcon(color: showing.deckColor, size: 16)
                Self.positionLabel(showing)
            }
            .padding(.horizontal, 12)
        }
    }

    private var cardContent: some View {
        CardPillContent(
            card: showing.card, deckColor: showing.deckColor, layout: cardLayout, notchWidth: notchWidth,
            flipInterval: flipInterval, startedAt: restStartedAt, isActive: isActive
        )
    }

    static func positionLabel(_ showing: NowShowing) -> some View {
        Text(showing.positionText)
            .font(Theme.Typography.micro.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.8))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

extension NowShowing {
    /// A made-up card for previews.
    static let sample = NowShowing(
        deckID: UUID(), deckName: "Spanish A2", deckColor: .green,
        card: Card(front: "la manzana", back: "the apple"),
        isFlipped: false, position: 12, total: 48, progress: 0.4, secondsRemaining: 180
    )
}

/// "What the pill shows": the styles with what each one shows, a live preview, and a note on where
/// it applies.
struct PillStylePicker: View {
    @Binding var selection: PillStyle
    /// Whether a drawn notch is on screen right now.
    var hasDrawnNotch: Bool
    /// How often the Card preview flips, as the notch does.
    var flipInterval: NotchFlipInterval = .default

    @Environment(\.accentChoice) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("What the pill shows")
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.TextColor.primary)
                Spacer(minLength: 8)
                preview
            }
            VStack(spacing: 2) {
                ForEach(PillStyle.available, id: \.self) { style in
                    row(style)
                }
            }
            Text(note)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What the pill shows")
    }

    /// The same view the notch draws, at its resting size.
    private var preview: some View {
        let isCard = PillStyle.resolved(selection) == .card
        let height: CGFloat = isCard ? NotchGeometry.cardRestSize.height : 24
        let width = NotchGeometry.drawnWidth(forPositionText: NowShowing.sample.positionText, style: selection)
        return ZStack {
            NotchShape(radius: 10).fill(Theme.Surface.notch)
            PillRestContent(
                style: selection, showing: .sample, hasCamera: false, notchWidth: 0,
                nextRotation: CardScheduler().nextRotation(after: Date()), study: .sample,
                flipInterval: flipInterval
            )
        }
        .frame(width: width, height: height)
        .environment(\.accentChoice, accent)
        .accessibilityHidden(true)
    }

    private func row(_ style: PillStyle) -> some View {
        let isSelected = style == selection
        return Button { selection = style } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.symbolName)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? accent.fill : Theme.TextColor.onControl)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.displayName)
                        .font(Theme.Typography.rowTitle.weight(isSelected ? .medium : .regular))
                        .foregroundStyle(Theme.TextColor.primary)
                    Text(style.summary)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.TextColor.primary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.TextColor.primary.with(opacity: 0.08))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.displayName). \(style.summary)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    var note: String {
        let base = "On a Mac with a notch the camera is in the middle: Card shows the text beside it, and the other styles show Classic there."
        return hasDrawnNotch ? base : base + " No drawn notch is on screen right now, so your choice applies when one appears."
    }
}

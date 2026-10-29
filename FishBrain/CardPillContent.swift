import AppKit
import SwiftUI

/// The resting Card notch (FLAS-89): only the card text, front in white and answer in orange,
/// flipping between them on its own. The flip is local to this view: it never goes through
/// `PlaybackActions`, writes nothing and doesn't reload the widgets.
struct CardPillContent: View {
    /// The card showing; nil for a deck with no cards, which shows the deck icon only.
    var card: Card?
    var deckColor: DeckColor
    var layout: CardRestLayout
    /// The camera's width on a real notch, the gap kept in the middle.
    var notchWidth: CGFloat
    var flipInterval: NotchFlipInterval = .default
    /// When the current card arrived or the notch last closed: the front shows from here.
    var startedAt = Date()
    /// False while the notch is open, hidden or asleep: nothing flips or slides.
    var isActive = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch layout {
        case .drawn:
            if let card, let width = layout.textWidth {
                flippingText(card, width: width, alignment: .center)
                    .padding(.horizontal, NotchGeometry.cardTextPadding)
            } else {
                DeckIcon(color: deckColor, size: 16)
            }
        case .besideCamera:
            HStack(spacing: 0) {
                Group {
                    if let card, let width = layout.textWidth {
                        flippingText(card, width: width, alignment: .trailing)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, NotchGeometry.snugTextPadding)
                .frame(width: NotchGeometry.snugTextWing)
                Spacer(minLength: 0).frame(width: notchWidth)
                DeckIcon(color: deckColor, size: 16)
                    .frame(maxWidth: .infinity)
            }
        case .deckOnly:
            HStack(spacing: 0) {
                Spacer(minLength: 0).frame(maxWidth: .infinity)
                Spacer(minLength: 0).frame(width: notchWidth)
                DeckIcon(color: deckColor, size: 16)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func flippingText(_ card: Card, width: CGFloat, alignment: Alignment) -> some View {
        let faces = NotchCardRest.faces(of: card)
        let frontFit = Self.fit(faces.front, width: width, reduceMotion: reduceMotion)
        let backFit = Self.fit(faces.back, width: width, reduceMotion: reduceMotion)
        let plan = NotchCardRest.FlipPlan(
            interval: flipInterval, hasBack: faces.back.hasContent,
            frontSlide: NotchCardRest.slideDuration(frontFit), backSlide: NotchCardRest.slideDuration(backFit)
        )
        let make = { (side: CardSide) in
            CardRestFlip(
                side: side, front: faces.front, back: faces.back, frontFit: frontFit, backFit: backFit,
                width: width, alignment: alignment, isActive: isActive, cardID: card.id, startedAt: startedAt
            )
        }
        if isActive && plan.flips {
            // Wakes only at the moments the side changes; nothing ticks in between.
            TimelineView(CardFlipSchedule(plan: plan, start: startedAt)) { context in
                make(plan.side(at: context.date.timeIntervalSince(startedAt)))
            }
        } else {
            make(.front)
        }
    }

    /// How a side's text fits the width: measured at 12 pt medium on one line.
    static func fit(_ face: NotchCardRest.Face, width: CGFloat, reduceMotion: Bool) -> NotchCardRest.Fit {
        guard case .text(let text) = face else { return .fits(fontSize: NotchCardRest.fontSize) }
        return NotchCardRest.fit(naturalWidth: naturalWidth(of: text), available: width, reduceMotion: reduceMotion)
    }

    static func naturalWidth(of text: String, fontSize: CGFloat = NotchCardRest.fontSize) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
}

/// The two sides, turned about a horizontal axis (or cross-faded with Reduce Motion).
private struct CardRestFlip: View {
    var side: CardSide
    var front: NotchCardRest.Face
    var back: NotchCardRest.Face
    var frontFit: NotchCardRest.Fit
    var backFit: NotchCardRest.Fit
    var width: CGFloat
    var alignment: Alignment
    var isActive: Bool
    var cardID: Card.ID
    var startedAt: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isBack = side == .back
        FlipView(
            angle: NotchCard.flipAngle(isFlipped: isBack),
            style: NotchCardRest.flipStyle(reduceMotion: reduceMotion),
            axis: (x: 1, y: 0, z: 0),
            front: face(front, fit: frontFit, color: Theme.NotchText.front, isShowing: !isBack),
            back: face(back, fit: backFit, color: Theme.NotchText.answer, isShowing: isBack)
        )
        .animation(.easeInOut(duration: NotchCardRest.flipDuration(reduceMotion: reduceMotion)), value: isBack)
        // A new card (or the notch closing) starts on the front at once, without flipping from the old one.
        .id(RestKey(cardID: cardID, startedAt: startedAt))
        .frame(width: width, height: NotchGeometry.cardRestSize.height)
    }

    private struct RestKey: Hashable {
        var cardID: Card.ID
        var startedAt: Date
    }

    private func face(_ face: NotchCardRest.Face, fit: NotchCardRest.Fit, color: Token, isShowing: Bool) -> some View {
        CardRestFace(face: face, fit: fit, color: color, width: width, alignment: alignment, isRunning: isActive && isShowing)
    }
}

/// One side: a line of text (centered, shrunk, sliding or cut off), "Picture", or nothing.
private struct CardRestFace: View {
    var face: NotchCardRest.Face
    var fit: NotchCardRest.Fit
    var color: Token
    var width: CGFloat
    var alignment: Alignment
    /// This side is on screen and the notch is resting, so long text may slide.
    var isRunning: Bool

    @State private var offset: CGFloat = 0

    var body: some View {
        switch face {
        case .empty:
            Spacer(minLength: 0).frame(width: width)
        case .picture:
            HStack(spacing: 4) {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .accessibilityHidden(true)
                Text("Picture")
                    .font(.system(size: NotchCardRest.fontSize, weight: .medium))
            }
            .foregroundStyle(Theme.NotchText.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
        case .text(let text):
            textView(text)
        }
    }

    @ViewBuilder
    private func textView(_ text: String) -> some View {
        let font = Font.system(size: fit.fontSize, weight: .medium)
        switch fit {
        case .fits:
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(width: width, alignment: alignment)
        case .truncates:
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width, alignment: alignment)
        case .slides(_, let overflow):
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .offset(x: offset)
                .frame(width: width, alignment: .leading)
                .clipped()
                .mask(edgeFade)
                .task(id: isRunning) {
                    guard isRunning else { return }
                    // Each time this side comes round it starts from the left again.
                    var reset = Transaction()
                    reset.disablesAnimations = true
                    withTransaction(reset) { offset = 0 }
                    try? await Task.sleep(for: .seconds(NotchCardRest.slideDelay))
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: TimeInterval(overflow / NotchCardRest.slideSpeed))) { offset = -overflow }
                }
        }
    }

    /// The text area's edges fade out, so sliding text never meets a hard edge.
    private var edgeFade: some View {
        let fade = min(NotchCardRest.edgeFade / max(width, 1), 0.5)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: fade),
                .init(color: .black, location: 1 - fade), .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }
}

/// The moments the resting card's side changes, from `start`.
struct CardFlipSchedule: TimelineSchedule {
    var plan: NotchCardRest.FlipPlan
    var start: Date

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        let plan = plan
        let start = start
        return AnySequence(sequence(first: startDate) { date in
            plan.nextChange(after: date.timeIntervalSince(start)).map { start.addingTimeInterval($0) }
        })
    }
}

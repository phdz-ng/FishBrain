import SwiftUI

/// A small fish drawn as shapes: crisp at any scale, in one color. The tail is its own shape so it
/// can swing.
struct FishView: View {
    var color: Color
    /// Degrees the tail is turned from straight behind the body.
    var tailAngle: Double

    static let size = CGSize(width: 20, height: 12)

    var body: some View {
        ZStack(alignment: .leading) {
            // Tail: a triangle whose point is at the body, turning around that point.
            TailShape()
                .fill(color)
                .frame(width: 7, height: 10)
                .rotationEffect(.degrees(tailAngle), anchor: .trailing)
            ZStack {
                Ellipse().fill(color)
                Circle().fill(Theme.Surface.notch.color).frame(width: 2, height: 2).offset(x: 4.5, y: -1)
            }
            .frame(width: 14, height: 9)
            .offset(x: 6)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }

    private struct TailShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

/// The fish pill's resting content: the deck icon, a fish swimming along a faint dashed line for as
/// long as the card lasts, and the position. When the next card arrives the old fish fades out where
/// it ended and a new one fades in at the start, instead of one swimming back across the pill.
struct FishPillContent: View {
    var showing: NowShowing
    var nextRotation: Date
    /// How long a card lasts, which is the length of the fish's swim.
    var interval = CardScheduler.defaultInterval
    /// False while the notch is open or hidden: nothing redraws then.
    var isActive: Bool

    static let trackWidth: CGFloat = 92

    @Environment(\.accentChoice) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 9) {
            DeckIcon(color: showing.deckColor, size: 16)
            // The animation sits on the parent so the old fish fades out as the new one fades in.
            ZStack {
                track
                    .id(nextRotation)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.3), value: nextRotation)
            PillRestContent.positionLabel(showing)
        }
        .padding(.horizontal, 12)
    }

    private var track: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.clear)
                .frame(height: 1)
                .overlay { DashedLine().stroke(Theme.TextColor.primary.with(opacity: 0.2), style: StrokeStyle(lineWidth: 1, dash: [2, 3])) }
            swimmer
        }
        .frame(width: Self.trackWidth, height: FishView.size.height)
    }

    @ViewBuilder
    private var swimmer: some View {
        if isActive {
            TimelineView(.periodic(from: .now, by: FishSwim.updatePeriod(reduceMotion: reduceMotion))) { context in
                fish(at: context.date)
            }
        } else {
            fish(at: Date())
        }
    }

    private func fish(at date: Date) -> some View {
        let progress = FishSwim.progress(until: nextRotation, now: date, interval: interval, reduceMotion: reduceMotion)
        let offset = FishSwim.offset(progress: progress, trackWidth: Self.trackWidth, fishWidth: FishView.size.width)
        // The tail flicks on each tick; with Reduce Motion it stays still.
        let tail: Double = reduceMotion ? 0 : (FishSwim.tailLeansUp(at: date) ? 16 : -16)
        return FishView(color: accent.light.color, tailAngle: tail)
            .offset(x: offset)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: offset)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: tail)
    }

    private struct DashedLine: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

import CoreGraphics
import Foundation

/// Layout and flip rules for the expanded notch card, kept free of UI so they can be tested.
enum NotchCard {
    /// Where the content starts, measured from the top of the panel. The top of the panel is the
    /// camera housing (or the menu bar), so content starts below it and never sits under it.
    static func contentTopInset(notchHeight: CGFloat) -> CGFloat {
        notchHeight + 10
    }

    /// The card flips through 180 degrees; past the quarter turn the back side is showing.
    static func isShowingBack(angle: Double) -> Bool {
        let a = angle.truncatingRemainder(dividingBy: 360)
        let normalized = a < 0 ? a + 360 : a
        return normalized >= 90 && normalized < 270
    }

    enum FlipStyle: Equatable, Sendable {
        /// The card turns around its vertical axis.
        case rotate
        /// The two faces dissolve into each other; nothing moves.
        case crossfade
    }

    /// With Reduce Motion on, the flip becomes a crossfade.
    static func flipStyle(reduceMotion: Bool) -> FlipStyle {
        reduceMotion ? .crossfade : .rotate
    }

    /// How visible each face is at a point in the flip (0 = front, 180 = back). Rotating, exactly one
    /// face shows at any moment; crossfading, the faces trade places smoothly.
    static func faceOpacities(angle: Double, style: FlipStyle) -> (front: Double, back: Double) {
        switch style {
        case .rotate:
            let back = isShowingBack(angle: angle)
            return (back ? 0 : 1, back ? 1 : 0)
        case .crossfade:
            let progress = min(max(angle / 180, 0), 1)
            return (1 - progress, progress)
        }
    }

    static func flipAngle(isFlipped: Bool) -> Double {
        isFlipped ? 180 : 0
    }

    /// Whole seconds left in the current slot, never below 1 (the card changes instead of showing 0:00).
    static func secondsRemaining(until nextRotation: Date, now: Date) -> Int {
        max(Int(nextRotation.timeIntervalSince(now).rounded(.up)), 1)
    }

    /// Fraction of the slot that has elapsed, 0...1.
    static func progress(until nextRotation: Date, now: Date, interval: TimeInterval = CardScheduler.defaultInterval) -> Double {
        min(max(1 - nextRotation.timeIntervalSince(now) / interval, 0), 1)
    }
}

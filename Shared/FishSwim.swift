import CoreGraphics
import Foundation

/// The swimming-fish pill: where the fish is along its track, and how often it is redrawn. Pure,
/// so the timing rules can be tested without a window.
enum FishSwim {
    /// How often the fish moves and flicks its tail. The slot is 5 minutes, so a position changes by a
    /// fraction of a point per second: a slow redraw looks the same and costs next to nothing.
    static let tick: TimeInterval = 5
    /// With Reduce Motion the fish moves in steps instead of gliding.
    static let reducedMotionStep: TimeInterval = 15

    static func updatePeriod(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? reducedMotionStep : tick
    }

    /// How far along the track the fish is, 0 (a card just arrived) to 1 (the next one is due).
    /// Worked out from the clock, so it is right after sleep and wake. With Reduce Motion it only
    /// takes whole steps.
    static func progress(
        until nextRotation: Date, now: Date, interval: TimeInterval = CardScheduler.defaultInterval, reduceMotion: Bool
    ) -> Double {
        let exact = NotchCard.progress(until: nextRotation, now: now, interval: interval)
        guard reduceMotion else { return exact }
        let elapsed = exact * interval
        let stepped = (elapsed / reducedMotionStep).rounded(.down) * reducedMotionStep
        return min(max(stepped / interval, 0), 1)
    }

    /// The fish's left edge along a track, keeping it inside both ends.
    static func offset(progress: Double, trackWidth: CGFloat, fishWidth: CGFloat) -> CGFloat {
        let travel = max(trackWidth - fishWidth, 0)
        return CGFloat(min(max(progress, 0), 1)) * travel
    }

    /// Which way the tail swings on a given tick, so it flicks one way, then the other.
    static func tailLeansUp(at date: Date) -> Bool {
        Int((date.timeIntervalSince1970 / tick).rounded(.down)) % 2 == 0
    }
}

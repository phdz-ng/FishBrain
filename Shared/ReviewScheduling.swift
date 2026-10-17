import Foundation

/// How well you knew a card, chosen after turning it over.
enum ReviewGrade: String, Codable, CaseIterable, Sendable {
    case again, hard, good, easy

    var displayName: String { rawValue.capitalized }

    /// The key that picks it in the open notch: 1 Again, 2 Hard, 3 Good, 4 Easy.
    var shortcutKey: Character {
        switch self {
        case .again: "1"
        case .hard: "2"
        case .good: "3"
        case .easy: "4"
        }
    }
}

/// When a card you have graded is next due, and what the grades have done to its schedule.
struct ReviewState: Codable, Hashable, Sendable {
    var due: Date
    /// The gap that was set when it was last graded.
    var interval: TimeInterval
    /// How fast the gap grows: each Good multiplies it by this. Starts at 2.5.
    var ease: Double
    /// Successful reviews in a row since the card was new or last forgotten. Zero means it is still
    /// being learned (new, or forgotten with Again).
    var reps: Int
    /// Times it was forgotten (Again after it had been learned).
    var lapses: Int
    var lastReviewed: Date
}

/// The scheduling rules, in one place so they can be swapped for another algorithm later. It is a
/// simple SM-2-style scheme:
///
/// - **Learning** (a new card, or one you forgot): Again 1 min, Hard 10 min, Good 1 day, Easy 4 days.
///   Good and Easy graduate it.
/// - **Reviewing** (graduated): Again starts it over (1 min, ease -0.2, a lapse); Hard grows the gap
///   by 1.2 (ease -0.15); Good by its ease (2.5 to start); Easy by ease x 1.3 (ease +0.15). Each
///   grade is at least a day longer than the one below it, so the four buttons never read the same.
enum ReviewScheduler {
    static let minute: TimeInterval = 60
    static let day: TimeInterval = 86_400
    static let startingEase = 2.5
    static let minimumEase = 1.3
    static let maximumInterval: TimeInterval = 3650 * day

    /// Where a card stands after a grade.
    static func graded(_ state: ReviewState?, _ grade: ReviewGrade, at now: Date) -> ReviewState {
        let learning = state == nil || state?.reps == 0
        let ease = state?.ease ?? startingEase
        let interval = interval(after: grade, from: state)
        var next = ReviewState(
            due: now.addingTimeInterval(interval),
            interval: interval,
            ease: ease,
            reps: state?.reps ?? 0,
            lapses: state?.lapses ?? 0,
            lastReviewed: now
        )
        switch grade {
        case .again:
            if !learning { next.lapses += 1 }
            next.reps = 0
            if !learning { next.ease = max(ease - 0.2, minimumEase) }
        case .hard:
            if learning { next.reps = 0 } else { next.reps += 1; next.ease = max(ease - 0.15, minimumEase) }
        case .good:
            next.reps += 1
        case .easy:
            next.reps += 1
            if !learning { next.ease = ease + 0.15 }
        }
        return next
    }

    /// The gap a grade would set: what the four buttons show.
    static func interval(after grade: ReviewGrade, from state: ReviewState?) -> TimeInterval {
        guard let state, state.reps > 0 else {
            switch grade {
            case .again: return minute
            case .hard: return 10 * minute
            case .good: return day
            case .easy: return 4 * day
            }
        }
        let current = max(state.interval, day)
        let hard = max(current * 1.2, day)
        let good = max(current * state.ease, hard + day)
        let easy = max(current * state.ease * 1.3, good + day)
        switch grade {
        case .again: return minute
        case .hard: return min(hard, maximumInterval)
        case .good: return min(good, maximumInterval)
        case .easy: return min(easy, maximumInterval)
        }
    }

    static func intervals(from state: ReviewState?) -> GradeIntervals {
        GradeIntervals(
            again: interval(after: .again, from: state), hard: interval(after: .hard, from: state),
            good: interval(after: .good, from: state), easy: interval(after: .easy, from: state)
        )
    }

    /// "1 min", "10 min", "3 h", "1 day", "4 days", "2 mo", "1 yr".
    static func label(for interval: TimeInterval) -> String {
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        switch interval {
        case ..<(60 * minute): return "\(max(Int((interval / minute).rounded()), 1)) min"
        case ..<day: return "\(max(Int((interval / 3600).rounded()), 1)) h"
        case ..<(30 * day): return plural(max(Int((interval / day).rounded()), 1), "day")
        case ..<(365 * day): return "\(max(Int((interval / (30 * day)).rounded()), 1)) mo"
        default: return "\(max(Int((interval / (365 * day)).rounded()), 1)) yr"
        }
    }
}

/// The four gaps the grade buttons show for the card on screen.
struct GradeIntervals: Equatable, Sendable {
    var again: TimeInterval
    var hard: TimeInterval
    var good: TimeInterval
    var easy: TimeInterval

    subscript(grade: ReviewGrade) -> TimeInterval {
        switch grade {
        case .again: again
        case .hard: hard
        case .good: good
        case .easy: easy
        }
    }

    func label(_ grade: ReviewGrade) -> String { ReviewScheduler.label(for: self[grade]) }

    /// What a card nobody has graded yet would show.
    static let forNewCard = ReviewScheduler.intervals(from: nil)
}

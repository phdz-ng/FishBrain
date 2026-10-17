import Foundation

/// Where one card stands, for the chip in the card list: New, Learning · 10 min, Due now, In 4 days,
/// Mastered · 3 mo. Derived from the card's `ReviewState` and the time, nothing else, so the list, the
/// tests and anything later (a deck summary, a filter) agree.
enum CardStatus: Equatable, Sendable {
    /// Never graded.
    case new
    /// Still being learned (new and graded Hard or Again, or forgotten): back in this long.
    case learning(TimeInterval)
    /// Graded, and its next review is now or past.
    case dueNow
    /// Graduated and not yet due: back in this long.
    case upcoming(TimeInterval)
    /// Graduated and a long way off: back in this long.
    case mastered(TimeInterval)

    /// A card is "mastered" when its next review is at least this far away.
    static let masteredThreshold: TimeInterval = 21 * ReviewScheduler.day

    init(_ review: ReviewState?, at now: Date) {
        guard let review else {
            self = .new
            return
        }
        let remaining = review.due.timeIntervalSince(now)
        if remaining <= 0 {
            self = .dueNow
        } else if review.reps == 0 {
            self = .learning(remaining)
        } else if remaining >= Self.masteredThreshold {
            self = .mastered(remaining)
        } else {
            self = .upcoming(remaining)
        }
    }

    /// "New", "Learning · 10 min", "Due now", "In 4 days", "Mastered · 3 mo".
    var text: String {
        switch self {
        case .new: "New"
        case .learning(let gap): "Learning · \(ReviewScheduler.label(for: gap))"
        case .dueNow: "Due now"
        case .upcoming(let gap): "In \(ReviewScheduler.label(for: gap))"
        case .mastered(let gap): "Mastered · \(ReviewScheduler.label(for: gap))"
        }
    }

    /// Which colors the chip wears.
    enum Tone: Equatable, Sendable { case neutral, learning, due, mastered }

    var tone: Tone {
        switch self {
        case .new, .upcoming: .neutral
        case .learning: .learning
        case .dueNow: .due
        case .mastered: .mastered
        }
    }

    /// What VoiceOver says after the card's text: "Status, due now".
    var accessibilityText: String {
        "Status, " + text.replacingOccurrences(of: " · ", with: ", ").lowercasedFirst
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

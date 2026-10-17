import Foundation

/// A Review sprint in progress: when it started, how long it is, how much of that has been paused, and
/// what has been graded. Shaped like `StudySession.Active`. Time left is worked out from the clock, so
/// sleeping and waking can't stretch a run; pausing stops the clock and resuming carries on.
struct ReviewRun: Codable, Equatable, Sendable {
    /// One grade given during the run.
    struct Graded: Codable, Equatable, Sendable {
        var cardID: Card.ID
        var deckID: Deck.ID
        var grade: ReviewGrade
        var at: Date
    }

    static let lengths = [5, 10, 15, 25]
    static let minutesRange = 1...60
    static let defaultMinutes = 10

    /// Any length from 1 to 60 minutes is allowed; others are brought into that range.
    static func clamped(minutes: Int) -> Int {
        min(max(minutes, minutesRange.lowerBound), minutesRange.upperBound)
    }

    var startedAt: Date
    var minutes: Int
    /// Time spent in pauses that have ended.
    private(set) var pausedTotal: TimeInterval = 0
    /// When the current pause began; nil while running.
    private(set) var pausedAt: Date?
    /// Set once the run is over, by the grade at 0:00 or by `end(at:)`.
    private(set) var endedAt: Date?
    private(set) var graded: [Graded] = []

    init(startedAt: Date, minutes: Int = ReviewRun.defaultMinutes) {
        self.startedAt = startedAt
        self.minutes = Self.clamped(minutes: minutes)
    }

    var duration: TimeInterval { Double(minutes) * 60 }
    var isPaused: Bool { pausedAt != nil && endedAt == nil }
    var isEnded: Bool { endedAt != nil }
    /// Cards graded: every grade given counts, so a card graded Again and later Good counts twice.
    var reviewed: Int { graded.count }

    // MARK: The clock

    /// Time the run has actually been running at `now`: a paused stretch isn't counted, and once the
    /// run has ended the clock is stopped at that moment. Never more than the run's length.
    func elapsed(at now: Date) -> TimeInterval {
        let stop = endedAt ?? now
        let paused = pausedTotal + (pausedAt.map { max(stop.timeIntervalSince($0), 0) } ?? 0)
        return min(max(stop.timeIntervalSince(startedAt) - paused, 0), duration)
    }

    /// Time left, never negative.
    func remaining(at now: Date) -> TimeInterval { duration - elapsed(at: now) }

    /// 0 at the start, 1 at 0:00.
    func progress(at now: Date) -> Double { elapsed(at: now) / duration }

    /// The clock has run out. The card on screen can still be graded, and that ends the run.
    func isTimeUp(at now: Date) -> Bool { remaining(at: now) <= 0 }

    mutating func pause(at now: Date) {
        guard !isEnded, pausedAt == nil, !isTimeUp(at: now) else { return }
        pausedAt = now
    }

    mutating func resume(at now: Date) {
        guard !isEnded, let start = pausedAt else { return }
        pausedTotal += max(now.timeIntervalSince(start), 0)
        pausedAt = nil
    }

    /// Ends the run early (or after its last grade). Stops the clock where it is.
    mutating func end(at now: Date) {
        guard !isEnded else { return }
        endedAt = now
    }

    // MARK: Grading

    /// Records a grade. Allowed until the run has ended, including at and after 0:00 for the card that
    /// was on screen; a grade given then ends the run. Returns false when the run had already ended.
    @discardableResult
    mutating func record(_ grade: ReviewGrade, cardID: Card.ID, deckID: Deck.ID, at now: Date) -> Bool {
        guard !isEnded else { return false }
        // Grading while paused carries on from where it was.
        resume(at: now)
        graded.append(Graded(cardID: cardID, deckID: deckID, grade: grade, at: now))
        if isTimeUp(at: now) { end(at: now) }
        return true
    }

    // MARK: How it went

    struct Summary: Equatable, Sendable {
        /// Grades given.
        var count: Int
        /// Cards a minute, over the time the run was actually running.
        var pace: Double
        var gradeCounts: [ReviewGrade: Int]
        var deckCounts: [Deck.ID: Int]
        /// Cards graded Again at least once, in the order they first were: the ones to look at again.
        var againCards: [Card.ID]
        /// How long it ran, pauses left out.
        var elapsed: TimeInterval
    }

    /// The summary at `now` (which only matters while the run is still going).
    func summary(at now: Date) -> Summary {
        let elapsed = elapsed(at: now)
        var gradeCounts = Dictionary(uniqueKeysWithValues: ReviewGrade.allCases.map { ($0, 0) })
        var deckCounts: [Deck.ID: Int] = [:]
        var again: [Card.ID] = []
        for entry in graded {
            gradeCounts[entry.grade, default: 0] += 1
            deckCounts[entry.deckID, default: 0] += 1
            if entry.grade == .again, !again.contains(entry.cardID) { again.append(entry.cardID) }
        }
        return Summary(
            count: graded.count,
            pace: elapsed >= 1 ? Double(graded.count) / (elapsed / 60) : 0,
            gradeCounts: gradeCounts,
            deckCounts: deckCounts,
            againCards: again,
            elapsed: elapsed
        )
    }

    /// The summary of a finished run, or of one measured at its last grade.
    var summary: Summary {
        summary(at: endedAt ?? graded.last?.at ?? startedAt)
    }
}

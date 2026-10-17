import Foundation

/// What a deck is showing at a given instant, ready for display. Computed from the same scheduler
/// the widget and notch use, so the in-app preview always agrees with them.
struct NowShowing: Equatable, Sendable {
    var deckID: Deck.ID
    var deckName: String
    var deckColor: DeckColor
    var card: Card
    var isFlipped: Bool
    /// 1-based position in the deck, e.g. 12 of 48.
    var position: Int
    var total: Int
    /// Fraction of the current slot that has elapsed, 0...1.
    var progress: Double
    /// Whole seconds until the next card, rounded up; 1...interval.
    var secondsRemaining: Int
    /// What each grade would set for this card, for the buttons under it.
    var gradeIntervals: GradeIntervals = .forNewCard
    /// Graded cards in this deck that are due right now.
    var dueCount = 0

    var positionText: String { "\(position)/\(total)" }

    /// "Everyday Spanish, card 12 of 48": the notch's resting state and widget headers, spoken.
    var accessibilitySummary: String { "\(deckName), card \(position) of \(total)" }
    var countdownText: String { Self.format(seconds: secondsRemaining) }

    static func make(
        deck: Deck,
        state: PlaybackState,
        at date: Date,
        scheduler: CardScheduler = CardScheduler()
    ) -> NowShowing? {
        guard let current = scheduler.currentCard(in: deck, state: state, at: date) else { return nil }
        let remaining = scheduler.nextRotation(after: date).timeIntervalSince(date)
        return NowShowing(
            deckID: deck.id,
            deckName: deck.name,
            deckColor: deck.color,
            card: current.card,
            isFlipped: current.isFlipped,
            position: current.index + 1,
            total: deck.cards.count,
            progress: min(max(1 - remaining / scheduler.interval, 0), 1),
            secondsRemaining: max(Int(remaining.rounded(.up)), 1),
            gradeIntervals: ReviewScheduler.intervals(from: state.review(for: current.card.id)),
            dueCount: state.dueCount(in: deck, at: date)
        )
    }

    /// "m:ss"
    static func format(seconds: Int) -> String {
        let clamped = max(seconds, 0)
        return "\(clamped / 60):" + String(format: "%02d", clamped % 60)
    }
}

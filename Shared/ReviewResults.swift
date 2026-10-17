import Foundation

/// What a finished Review sprint says about itself: the big count, the pace, how the grades fell, the
/// split by deck and the cards that came up again. Pure, so it can be tested from a fixed `ReviewRun`.
struct ReviewResults: Equatable, Sendable {
    enum Ending: Equatable, Sendable {
        /// The clock ran out.
        case timeUp
        /// "End sprint".
        case ended
        /// Every card in the queue has been through.
        case queueFinished
    }

    /// Past sprints, once there is history (the sprint history story); nil hides the chips.
    struct History: Equatable, Sendable {
        var usualPace: Double?
        var lastCount: Int?
        var lastSeconds: TimeInterval?

        static let empty = History()
    }

    struct DeckRow: Equatable, Sendable {
        var deckID: Deck.ID
        var name: String
        var count: Int
        /// Relative to the busiest deck, for the bar.
        var fraction: Double
    }

    struct AgainRow: Equatable, Sendable {
        var cardID: Card.ID
        var deckID: Deck.ID
        var front: String
        var deckName: String
    }

    var ending: Ending
    var count: Int
    var elapsed: TimeInterval
    var pace: Double
    var deckCount: Int
    var gradeCounts: [ReviewGrade: Int]
    var byDeck: [DeckRow]
    var again: [AgainRow]
    /// The cards graded Again with their decks, in the order they were first forgotten.
    var againEntries: [ReviewQueue.Entry]
    var history: History
    var goalLine: String?

    init(
        run: ReviewRun,
        ending: Ending,
        decks: [Deck],
        study: StudySummary? = nil,
        history: History = .empty,
        mixDeckCount: Int? = nil,
        now: Date? = nil
    ) {
        let summary = now.map(run.summary(at:)) ?? run.summary
        self.ending = ending
        count = summary.count
        elapsed = summary.elapsed
        pace = summary.pace
        gradeCounts = summary.gradeCounts
        self.history = history
        goalLine = study.map(Self.goalLine)

        let names = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0.name) })
        let fronts = Dictionary(uniqueKeysWithValues: decks.flatMap { deck in deck.cards.map { ($0.id, $0.front) } })
        // Decks in the order they first came up.
        var order: [Deck.ID] = []
        for entry in run.graded where !order.contains(entry.deckID) { order.append(entry.deckID) }
        let busiest = max(summary.deckCounts.values.max() ?? 1, 1)
        byDeck = order.map { id in
            DeckRow(
                deckID: id, name: names[id] ?? "Deleted deck", count: summary.deckCounts[id] ?? 0,
                fraction: Double(summary.deckCounts[id] ?? 0) / Double(busiest)
            )
        }.sorted { $0.count > $1.count }
        // "4 decks" is how many were in the mix, whether or not each got a card in before time ran out.
        deckCount = mixDeckCount ?? order.count

        var deckForCard: [Card.ID: Deck.ID] = [:]
        for entry in run.graded { deckForCard[entry.cardID] = entry.deckID }
        againEntries = summary.againCards.compactMap { id in
            deckForCard[id].map { ReviewQueue.Entry(cardID: id, deckID: $0) }
        }
        again = againEntries.compactMap { entry in
            // A card deleted since has no words to show.
            fronts[entry.cardID].map { AgainRow(cardID: entry.cardID, deckID: entry.deckID, front: $0, deckName: names[entry.deckID] ?? "") }
        }
    }

    // MARK: Words

    /// "Time's up · 4 decks"
    var headline: String {
        let lead = switch ending {
        case .timeUp: "Time's up"
        case .ended: "Sprint ended"
        case .queueFinished: "All done"
        }
        return "\(lead) · \(deckCount) \(deckCount == 1 ? "deck" : "decks")"
    }

    /// "cards in 10:00 · 2.3 a minute"
    var paceLine: String {
        "\(count == 1 ? "card" : "cards") in \(Self.clock(elapsed)) · \(Self.paceText(pace))"
    }

    /// Good or Easy.
    var remembered: Int { (gradeCounts[.good] ?? 0) + (gradeCounts[.easy] ?? 0) }
    /// "16 of 23"
    var rememberedText: String { "\(remembered) of \(count)" }

    /// How wide each grade's part of the stacked bar is, in grade order; they add up to 1 (or all 0).
    var gradeFractions: [(grade: ReviewGrade, fraction: Double)] {
        ReviewGrade.allCases.map { ($0, count == 0 ? 0 : Double(gradeCounts[$0] ?? 0) / Double(count)) }
    }

    var usualPaceText: String? { history.usualPace.map(Self.paceText) }

    /// "19 cards in 10:00"
    var lastSprintText: String? {
        guard let count = history.lastCount, let seconds = history.lastSeconds else { return nil }
        return "\(count) \(count == 1 ? "card" : "cards") in \(Self.clock(seconds))"
    }

    /// "Review the 3 missed · 1 min"; nil when nothing came up again.
    var followUpTitle: String? {
        againEntries.isEmpty ? nil : "Review the \(againEntries.count) missed · 1 min"
    }

    /// The round that follows: exactly the cards graded Again, once each, in the order they were first
    /// forgotten. A sprint on it runs for a minute.
    static let followUpMinutes = 1
    func followUpQueue() -> ReviewQueue { ReviewQueue(entries: againEntries) }

    // MARK: Formatting

    /// "10:00", "4:12", "0:45"
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(Int(seconds.rounded()), 0)
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// "2.3 a minute"
    static func paceText(_ pace: Double) -> String { String(format: "%.1f a minute", pace) }

    /// "41 of 30 today, goal reached · 13-day streak"
    static func goalLine(_ study: StudySummary) -> String {
        var line = "\(study.count) of \(study.goal) today"
        if study.goalMetToday { line += ", goal reached" }
        if study.streak > 0 { line += " · \(study.streak)-day streak" }
        return line
    }
}

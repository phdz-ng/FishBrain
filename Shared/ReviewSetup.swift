import Foundation

/// What the Review sprint's setup sheet has chosen: which decks, how long and which cards.
struct ReviewSetup: Equatable, Sendable {
    var ticked: Set<Deck.ID> = []
    var minutes = ReviewRun.defaultMinutes
    var cards: ReviewQueue.Options.Cards = .dueThenNew
    var shuffleBetweenDecks = false

    /// The sheet opens with the deck you were looking at ticked.
    init(startingWith deckID: Deck.ID? = nil, minutes: Int = ReviewRun.defaultMinutes) {
        if let deckID { ticked = [deckID] }
        self.minutes = ReviewRun.clamped(minutes: minutes)
    }

    var options: ReviewQueue.Options {
        ReviewQueue.Options(cards: cards, shuffleBetweenDecks: shuffleBetweenDecks)
    }

    mutating func toggle(_ id: Deck.ID) {
        if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
    }

    /// "This deck".
    mutating func tickOnly(_ id: Deck.ID) { ticked = [id] }

    /// "Everything due": every deck that has a card due.
    mutating func tickEverythingDue(decks: [Deck], playback: [Deck.ID: PlaybackState], now: Date) {
        ticked = Set(decks.filter { ReviewSetupSummary.counts(for: $0, state: playback[$0.id], now: now).due > 0 }.map(\.id))
    }

    mutating func clear() { ticked = [] }

    mutating func setMinutes(_ minutes: Int) { self.minutes = ReviewRun.clamped(minutes: minutes) }
}

/// How many cards of a deck are due, new, and in all.
struct ReviewDeckCounts: Equatable, Sendable {
    var due = 0
    var new = 0
    var total = 0

    /// "14 due", or "Caught up" when nothing is.
    var dueText: String { due == 0 ? "Caught up" : "\(due) due" }
}

/// The numbers on the setup sheet: what the ticked decks hold, what each choice of cards would give,
/// the estimate, and whether Start is allowed. Pure.
struct ReviewSetupSummary: Equatable, Sendable {
    var tickedDecks: Int
    var due: Int
    var new: Int
    var total: Int
    var minutes: Int
    var cards: ReviewQueue.Options.Cards
    /// Cards a sprint with the current choices would go through.
    var queueCount: Int
    /// Cards a minute from past sprints; nil until there is history.
    var usualPace: Double?

    static func counts(for deck: Deck, state: PlaybackState?, now: Date) -> ReviewDeckCounts {
        var counts = ReviewDeckCounts(total: deck.cards.count)
        for card in deck.cards {
            if let review = state?.review(for: card.id) {
                if review.due <= now { counts.due += 1 }
            } else {
                counts.new += 1
            }
        }
        return counts
    }

    init(decks: [Deck], playback: [Deck.ID: PlaybackState], setup: ReviewSetup, now: Date, usualPace: Double? = nil) {
        let chosen = decks.filter { setup.ticked.contains($0.id) }
        var due = 0, new = 0, total = 0
        for deck in chosen {
            let counts = Self.counts(for: deck, state: playback[deck.id], now: now)
            due += counts.due
            new += counts.new
            total += counts.total
        }
        tickedDecks = chosen.count
        self.due = due
        self.new = new
        self.total = total
        minutes = setup.minutes
        cards = setup.cards
        self.usualPace = usualPace
        queueCount = switch setup.cards {
        case .dueThenNew: due + new
        case .dueOnly: due
        case .everythingShuffled: total
        }
    }

    /// "4 decks ticked · 20 due · 34 new"
    var summaryLine: String {
        "\(tickedDecks) \(tickedDecks == 1 ? "deck" : "decks") ticked · \(due) due · \(new) new"
    }

    /// What each choice of cards would give, shown on its row.
    func countText(for cards: ReviewQueue.Options.Cards) -> String {
        func cardsText(_ n: Int) -> String { "\(n) \(n == 1 ? "card" : "cards")" }
        switch cards {
        case .dueThenNew: return new > 0 ? "\(due) due, then \(new) new" : "\(due) due"
        case .dueOnly: return cardsText(due)
        case .everythingShuffled: return cardsText(total)
        }
    }

    /// "Start 10:00"
    var startTitle: String { "Start " + ReviewResults.clock(Double(minutes) * 60) }

    /// Why Start is off, or nil when it is on.
    var startDisabledReason: String? {
        if tickedDecks == 0 { return "Tick at least one deck." }
        if queueCount == 0 {
            return cards == .dueOnly ? "Nothing is due in the ticked decks." : "The ticked decks have no cards."
        }
        return nil
    }

    /// "About 21 cards at your usual 2.1 a minute, across 4 decks." Hidden until there is history.
    /// With fewer cards than the time would take, it says all of them fit.
    var estimateLine: String? {
        guard let pace = usualPace, pace > 0, queueCount > 0, tickedDecks > 0 else { return nil }
        let across = "across \(tickedDecks) \(tickedDecks == 1 ? "deck" : "decks")"
        let paceText = ReviewResults.paceText(pace)
        let fits = Int((pace * Double(minutes)).rounded())
        if fits >= queueCount {
            return "All \(queueCount) \(queueCount == 1 ? "card" : "cards") should fit at your usual \(paceText), \(across)."
        }
        return "About \(max(fits, 1)) cards at your usual \(paceText), \(across)."
    }
}

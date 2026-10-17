import Foundation

/// The order a Review sprint takes cards in, over any set of decks (a mix is just a bigger set). Pure:
/// it is built once, when the sprint starts, from the decks as they are then, and from there it holds
/// only ids, so editing, moving or deleting decks and cards meanwhile can't change it.
struct ReviewQueue: Equatable, Codable, Sendable {
    /// A card and the deck it is in.
    struct Entry: Hashable, Codable, Sendable {
        var cardID: Card.ID
        var deckID: Deck.ID
    }

    struct Options: Equatable, Codable, Sendable {
        enum Cards: String, Codable, CaseIterable, Sendable {
            /// Cards that are due, most overdue first, then cards nobody has graded yet.
            case dueThenNew
            /// Only cards that are due.
            case dueOnly
            /// Every card in the decks, in a random order, due or not.
            case everythingShuffled
        }

        var cards: Cards = .dueThenNew
        /// Decks take turns instead of the most overdue cards coming first across all of them.
        var shuffleBetweenDecks = false

        init(cards: Cards = .dueThenNew, shuffleBetweenDecks: Bool = false) {
            self.cards = cards
            self.shuffleBetweenDecks = shuffleBetweenDecks
        }
    }

    /// How many other cards come before a card graded Again is shown again. Its gap is one minute, so
    /// this puts it back far enough on that the minute has plausibly passed, and near enough that it
    /// happens inside the sprint.
    static let againOffset = 4

    /// What is left, in the order it will be shown. The first is the card on screen.
    private(set) var entries: [Entry]

    var current: Entry? { entries.first }
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    init(entries: [Entry] = []) {
        self.entries = entries
    }

    // MARK: Building

    /// - Parameters:
    ///   - decks: the decks to review; a deck listed twice counts once.
    ///   - playback: each deck's playback state, which is where its cards' reviews are kept.
    ///   - now: what "due" is measured at.
    ///   - generator: only used by `everythingShuffled` and `shuffleBetweenDecks`.
    ///
    /// With `shuffleBetweenDecks` off the due cards come most overdue first across all the decks (a tie
    /// keeps deck order, then card order) and the new cards follow in deck order. With it on, the decks
    /// take turns, one card each in a random order of decks, due cards first and then new ones; each
    /// deck's own order is kept. `everythingShuffled` ignores both and shuffles every card.
    static func build<G: RandomNumberGenerator>(
        decks: [Deck],
        playback: [Deck.ID: PlaybackState],
        options: Options = Options(),
        now: Date,
        using generator: inout G
    ) -> ReviewQueue {
        var seen = Set<Deck.ID>()
        let decks = decks.filter { seen.insert($0.id).inserted }

        if options.cards == .everythingShuffled {
            var all = decks.flatMap { deck in deck.cards.map { Entry(cardID: $0.id, deckID: deck.id) } }
            all.shuffle(using: &generator)
            return ReviewQueue(entries: all)
        }

        // Per deck: the due cards, most overdue first, and the new cards in deck order.
        let parts: [Part] = decks.map { deck in
            let state = playback[deck.id] ?? PlaybackState()
            var part = Part()
            for (position, card) in deck.cards.enumerated() {
                let entry = Entry(cardID: card.id, deckID: deck.id)
                if let review = state.review(for: card.id) {
                    if review.due <= now { part.due.append((entry, review.due, position)) }
                } else {
                    part.new.append(entry)
                }
            }
            part.due.sort { ($0.due, $0.position) < ($1.due, $1.position) }
            return part
        }

        let includesNew = options.cards == .dueThenNew
        if options.shuffleBetweenDecks {
            var turns = Array(parts.indices)
            turns.shuffle(using: &generator)
            let due = interleave(turns.map { parts[$0].due.map(\.entry) })
            let new = includesNew ? interleave(turns.map { parts[$0].new }) : []
            return ReviewQueue(entries: due + new)
        }

        let due = parts.enumerated()
            .flatMap { deckIndex, part in part.due.map { (entry: $0.entry, due: $0.due, deck: deckIndex, card: $0.position) } }
            .sorted { ($0.due, $0.deck, $0.card) < ($1.due, $1.deck, $1.card) }
            .map(\.entry)
        let new = includesNew ? parts.flatMap(\.new) : []
        return ReviewQueue(entries: due + new)
    }

    static func build(decks: [Deck], playback: [Deck.ID: PlaybackState], options: Options = Options(), now: Date) -> ReviewQueue {
        var generator = SystemRandomNumberGenerator()
        return build(decks: decks, playback: playback, options: options, now: now, using: &generator)
    }

    /// The decks with these ids, in the library's order, for when a sprint starts from ticked rows (a
    /// ticked subject has already been resolved to its decks' ids). Ids that aren't in the library are
    /// ignored.
    static func build<G: RandomNumberGenerator>(
        deckIDs: Set<Deck.ID>,
        in library: [Deck],
        playback: [Deck.ID: PlaybackState],
        options: Options = Options(),
        now: Date,
        using generator: inout G
    ) -> ReviewQueue {
        build(
            decks: library.filter { deckIDs.contains($0.id) },
            playback: playback, options: options, now: now, using: &generator
        )
    }

    static func build(
        deckIDs: Set<Deck.ID>, in library: [Deck], playback: [Deck.ID: PlaybackState],
        options: Options = Options(), now: Date
    ) -> ReviewQueue {
        var generator = SystemRandomNumberGenerator()
        return build(deckIDs: deckIDs, in: library, playback: playback, options: options, now: now, using: &generator)
    }

    /// One deck's cards, sorted for the queue.
    private struct Part {
        var due: [(entry: Entry, due: Date, position: Int)] = []
        var new: [Entry] = []
    }

    /// One from each list in turn until all are empty.
    private static func interleave(_ lists: [[Entry]]) -> [Entry] {
        var result: [Entry] = []
        var round = 0
        while true {
            var added = false
            for list in lists where round < list.count {
                result.append(list[round])
                added = true
            }
            if !added { return result }
            round += 1
        }
    }

    // MARK: Going through it

    /// Drops the card on screen without grading it, for one that has been deleted since the sprint began.
    @discardableResult
    mutating func dropCurrent() -> Entry? {
        entries.isEmpty ? nil : entries.removeFirst()
    }

    /// Takes the card on screen off the queue. A card graded Again goes back `againOffset` cards on (or
    /// to the end, if fewer are left), and again after each further Again; Hard, Good and Easy are done
    /// with it for this sprint. Returns the card, or nil when the queue was empty.
    @discardableResult
    mutating func grade(_ grade: ReviewGrade, reinsertingAgainAfter offset: Int = ReviewQueue.againOffset) -> Entry? {
        guard !entries.isEmpty else { return nil }
        let entry = entries.removeFirst()
        if grade == .again {
            entries.insert(entry, at: min(max(offset, 0), entries.count))
        }
        return entry
    }
}

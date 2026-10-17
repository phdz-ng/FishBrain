import Foundation

/// Per-deck playback state shared by the widget and the notch: how many cards the user has
/// skipped, and which card (if any) is currently flipped to its back.
struct PlaybackState: Codable, Hashable, Sendable {
    struct Flip: Codable, Hashable, Sendable {
        /// The rotation position (slot + skip offset) the flip was made at.
        var position: Int
        var cardID: UUID
    }

    var skipOffset = 0
    var flip: Flip?
    /// What grading has done to this deck's cards, by card id (as a string, for JSON). A card that has
    /// never been graded has no entry. Kept here, in the shared playback file, because the app, the
    /// notch and the widget all grade and all need the same answer.
    var reviews: [String: ReviewState] = [:]

    init(skipOffset: Int = 0, flip: Flip? = nil, reviews: [String: ReviewState] = [:]) {
        self.skipOffset = skipOffset
        self.flip = flip
        self.reviews = reviews
    }

    /// Older files have no reviews.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skipOffset = try container.decodeIfPresent(Int.self, forKey: .skipOffset) ?? 0
        flip = try container.decodeIfPresent(Flip.self, forKey: .flip)
        reviews = try container.decodeIfPresent([String: ReviewState].self, forKey: .reviews) ?? [:]
    }

    func review(for cardID: Card.ID) -> ReviewState? { reviews[cardID.uuidString] }

    /// The cards that have been graded and are due at `date`, the most overdue first (ties keep deck
    /// order). Cards nobody has graded are never in it.
    func dueCards(in deck: Deck, at date: Date) -> [Card] {
        guard !reviews.isEmpty else { return [] }
        return deck.cards.enumerated()
            .compactMap { index, card -> (Int, Card, Date)? in
                guard let review = review(for: card.id), review.due <= date else { return nil }
                return (index, card, review.due)
            }
            .sorted { ($0.2, $0.0) < ($1.2, $1.0) }
            .map(\.1)
    }

    func dueCount(in deck: Deck, at date: Date) -> Int {
        guard !reviews.isEmpty else { return 0 }
        return deck.cards.reduce(0) { count, card in
            count + (review(for: card.id).map { $0.due <= date } == true ? 1 : 0)
        }
    }
}

struct ScheduledCard: Equatable, Sendable {
    var card: Card
    var index: Int
    var isFlipped: Bool
}

/// Decides which card a deck shows at any moment. Pure functions of (deck, state, time), so every
/// surface that evaluates it at the same time agrees without coordinating.
struct CardScheduler: Sendable {
    static let defaultInterval: TimeInterval = 5 * 60

    var interval: TimeInterval
    /// Where slot 0 begins, in seconds since the Unix epoch. The normal rotation counts from the epoch
    /// so every surface agrees; a study session counts from the moment it starts, so its first card
    /// lasts a full slot.
    var origin: TimeInterval

    init(interval: TimeInterval = CardScheduler.defaultInterval, origin: TimeInterval = 0) {
        self.interval = interval
        self.origin = origin
    }

    /// Time is split into fixed slots counted from `origin` (the Unix epoch unless a session says
    /// otherwise), shared by all decks.
    func slot(at date: Date) -> Int {
        Int(((date.timeIntervalSince1970 - origin) / interval).rounded(.down))
    }

    /// Where the rotation stands: advances once per slot and once per skip. A flip only lasts
    /// for the position it was made at, so rotating or skipping always lands on a front.
    func position(state: PlaybackState, at date: Date) -> Int {
        slot(at: date) + state.skipOffset
    }

    func nextRotation(after date: Date) -> Date {
        Date(timeIntervalSince1970: origin + Double(slot(at: date) + 1) * interval)
    }

    /// Where the slot containing `date` began. Which cards are due is judged here, not at `date`, so
    /// everything showing the deck during one slot agrees about which card it is.
    func slotStart(at date: Date) -> Date {
        Date(timeIntervalSince1970: origin + Double(slot(at: date)) * interval)
    }

    func currentCard(in deck: Deck, state: PlaybackState, at date: Date) -> ScheduledCard? {
        guard !deck.cards.isEmpty else { return nil }
        let position = position(state: state, at: date)
        // Graded cards that have come due go first, the most overdue first, and rotate among
        // themselves. With none due (and always, for someone who never grades) it is the plain
        // rotation through the whole deck.
        let due = state.dueCards(in: deck, at: slotStart(at: date))
        if !due.isEmpty {
            let card = due[((position % due.count) + due.count) % due.count]
            let index = deck.cards.firstIndex { $0.id == card.id } ?? 0
            return ScheduledCard(card: card, index: index, isFlipped: state.flip == PlaybackState.Flip(position: position, cardID: card.id))
        }
        let count = deck.cards.count
        let index = ((position % count) + count) % count
        let card = deck.cards[index]
        let isFlipped = state.flip == PlaybackState.Flip(position: position, cardID: card.id)
        return ScheduledCard(card: card, index: index, isFlipped: isFlipped)
    }

    /// Toggles the current card between front and back.
    func flipping(_ state: PlaybackState, in deck: Deck, at date: Date) -> PlaybackState {
        guard let current = currentCard(in: deck, state: state, at: date) else { return state }
        var next = state
        next.flip = current.isFlipped
            ? nil
            : PlaybackState.Flip(position: position(state: state, at: date), cardID: current.card.id)
        return next
    }

    /// Advances to the next card immediately and clears any flip.
    func skipping(_ state: PlaybackState, in deck: Deck, at date: Date) -> PlaybackState {
        guard !deck.cards.isEmpty else { return state }
        var next = state
        next.skipOffset += 1
        next.flip = nil
        return next
    }
}

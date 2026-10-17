import Foundation

/// Where someone is in Learn mode: the order the deck's cards are in, which one is showing, and
/// whether it is turned over. Pure, and kept only while the Learn screen is open: it never touches
/// `PlaybackState` (the skip offset and the flip the widget and notch rotate by) or any card's review.
struct LearnSession: Equatable, Sendable {
    /// The cards in the order they are being shown; shuffling rewrites it, leaving the screen drops it.
    private(set) var order: [Card.ID]
    private(set) var index = 0
    private(set) var isFlipped = false
    /// Past the last card: the "Round complete" state.
    private(set) var isComplete = false

    init(deck: Deck) {
        order = deck.cards.map(\.id)
    }

    /// Several decks, one after another in the order given (a subject's decks, "Learn all"). A card is
    /// in the order once.
    init(decks: [Deck]) {
        var seen = Set<Card.ID>()
        order = decks.flatMap(\.cards).map(\.id).filter { seen.insert($0).inserted }
    }

    /// Learn opens on a deck with at least one card.
    static func canStart(_ deck: Deck) -> Bool { !deck.cards.isEmpty }
    static func canStart(_ decks: [Deck]) -> Bool { decks.contains { !$0.cards.isEmpty } }

    var total: Int { order.count }
    var isEmpty: Bool { order.isEmpty }

    /// The card showing; nil in the empty deck and once the round is complete.
    var currentCardID: Card.ID? {
        isComplete || order.isEmpty ? nil : order[index]
    }

    /// "12 / 48"; "48 / 48" once the round is complete.
    var positionText: String {
        isEmpty ? "0 / 0" : "\(isComplete ? total : index + 1) / \(total)"
    }

    /// How far along the round is, 0 (first card) to 1 (last card, or complete): where the fish swims.
    var progress: Double {
        if isComplete { return 1 }
        return total > 1 ? Double(index) / Double(total - 1) : 0
    }

    /// Left arrow does something: not on the first card.
    var canGoBack: Bool { isComplete || index > 0 }
    /// Right arrow does something: on the last card it completes the round.
    var canGoForward: Bool { !isComplete && !isEmpty }

    /// Turns the card over, or back. Returns the card's id when it was just turned to its answer, which
    /// is the moment it counts as studied.
    @discardableResult
    mutating func flip() -> Card.ID? {
        guard let id = currentCardID else { return nil }
        isFlipped.toggle()
        return isFlipped ? id : nil
    }

    /// The next card, or the end of the round after the last. Always lands on a front.
    mutating func next() {
        guard canGoForward else { return }
        isFlipped = false
        if index == total - 1 { isComplete = true } else { index += 1 }
    }

    /// The previous card; stops at the first. From the end of the round it returns to the last card.
    mutating func previous() {
        guard canGoBack else { return }
        isFlipped = false
        if isComplete { isComplete = false } else { index -= 1 }
    }

    /// Mixes the order and starts again from the first card. Every card appears exactly once.
    mutating func shuffle<G: RandomNumberGenerator>(using generator: inout G) {
        order.shuffle(using: &generator)
        restart()
    }

    mutating func shuffle() {
        var generator = SystemRandomNumberGenerator()
        shuffle(using: &generator)
    }

    /// Back to the first card of the same order ("Go again").
    mutating func restart() {
        index = 0
        isFlipped = false
        isComplete = false
    }

    /// Follows the deck if it changed while the screen was open: deleted cards leave the order, new
    /// ones join the end, and the card showing stays showing when it still exists.
    mutating func sync(with deck: Deck) {
        sync(with: [deck])
    }

    /// The same for several decks.
    mutating func sync(with decks: [Deck]) {
        var seenIDs = Set<Card.ID>()
        let ids = decks.flatMap(\.cards).map(\.id).filter { seenIDs.insert($0).inserted }
        let present = Set(ids)
        guard present != Set(order) || ids.count != order.count else { return }
        let current = currentCardID
        let known = Set(order)
        order = order.filter(present.contains) + ids.filter { !known.contains($0) }
        if let current, let kept = order.firstIndex(of: current) {
            index = kept
        } else {
            index = min(index, max(order.count - 1, 0))
            isFlipped = false
        }
        if order.isEmpty { isComplete = false }
    }
}

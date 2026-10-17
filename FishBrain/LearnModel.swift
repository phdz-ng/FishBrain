import Foundation

/// The Learn screen's state: a `LearnSession` plus the one side effect Learn has, counting a card
/// toward today's goal when it is turned to its answer. It holds the deck's order only while the
/// screen is open, and never writes playback state or a card's review.
@MainActor
final class LearnModel: ObservableObject {
    @Published private(set) var session: LearnSession

    /// Called with the card and the moment when a card is turned to its answer.
    var recordStudied: ((Card.ID, Date) -> Void)?
    private let clock: () -> Date

    convenience init(deck: Deck, clock: @escaping () -> Date = { Date() }, recordStudied: ((Card.ID, Date) -> Void)? = nil) {
        self.init(decks: [deck], clock: clock, recordStudied: recordStudied)
    }

    /// A subject's decks, one after another ("Learn all").
    init(decks: [Deck], clock: @escaping () -> Date = { Date() }, recordStudied: ((Card.ID, Date) -> Void)? = nil) {
        session = LearnSession(decks: decks)
        self.clock = clock
        self.recordStudied = recordStudied
    }

    func flip() {
        guard let studied = session.flip() else { return }
        recordStudied?(studied, clock())
    }

    func next() { session.next() }
    func previous() { session.previous() }
    func shuffle() { session.shuffle() }
    func goAgain() { session.restart() }
    func sync(with deck: Deck) { session.sync(with: deck) }
    func sync(with decks: [Deck]) { session.sync(with: decks) }
}

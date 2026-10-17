import XCTest

@MainActor
final class CardEditingTests: XCTestCase {
    private var directory: URL!
    private var storage: DeckStorage!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = DeckStorage(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let cards = (1...4).map { Card(front: "f\($0)", back: "b\($0)") }

    private func makeStore() throws -> (DeckStore, Deck.ID) {
        let deck = Deck(name: "D", cards: cards)
        try storage.save([deck, Deck(name: "Other", cards: [Card(front: "x", back: "y")])])
        return (DeckStore(storage: storage, debounce: .milliseconds(10), onSaved: {}), deck.id)
    }

    // MARK: Add

    func testAddCardAppendsAnEmptyCardToTheEnd() throws {
        let (store, id) = try makeStore()
        let card = try XCTUnwrap(store.addCard(to: id))

        XCTAssertEqual(store.decks[0].cards.last, card)
        XCTAssertEqual(card.front, "")
        XCTAssertEqual(card.back, "")
        XCTAssertEqual(store.decks[0].cards.count, 5)
        XCTAssertEqual(store.decks[1].cards.count, 1, "other decks are untouched")
    }

    func testAddCardToAnUnknownDeckDoesNothing() throws {
        let (store, _) = try makeStore()
        XCTAssertNil(store.addCard(to: UUID()))
    }

    // MARK: Edit

    func testUpdateCardChangesOnlyThatCard() throws {
        let (store, id) = try makeStore()
        store.updateCard(cards[1].id, in: id) { $0.front = "edited" }

        XCTAssertEqual(store.decks[0].cards.map(\.front), ["f1", "edited", "f3", "f4"])
        XCTAssertEqual(store.decks[0].cards[1].back, "b2")
        XCTAssertEqual(store.decks[0].cards[1].id, cards[1].id, "the id is stable across edits")
    }

    func testNoOpEditDoesNotTriggerASave() throws {
        let (store, id) = try makeStore()
        store.updateCard(cards[0].id, in: id) { $0.front = "f1" }
        XCTAssertNil(store.pendingSave)
    }

    // MARK: Delete

    func testDeleteCardsRemovesOnlyThoseCards() throws {
        let (store, id) = try makeStore()
        store.deleteCards([cards[0].id, cards[2].id], in: id)
        XCTAssertEqual(store.decks[0].cards.map(\.front), ["f2", "f4"])
    }

    /// A row that was just deleted can still deliver a late text change or lookup; both must be harmless.
    func testEditsAndLookupsForADeletedCardAreHarmless() throws {
        let (store, id) = try makeStore()
        let gone = cards[1].id
        store.deleteCards([gone], in: id)

        store.updateCard(gone, in: id) { $0.front = "ghost" }
        store.deleteCards([gone], in: id)

        XCTAssertNil(store.card(gone, in: id))
        XCTAssertEqual(store.decks[0].cards.map(\.front), ["f1", "f3", "f4"], "nothing resurrected or shifted")
    }

    func testEditingOneCardAfterDeletingAnotherHitsTheRightCard() throws {
        let (store, id) = try makeStore()
        store.deleteCards([cards[0].id], in: id) // indexes shift
        store.updateCard(cards[2].id, in: id) { $0.back = "still the right card" }

        XCTAssertEqual(store.card(cards[2].id, in: id)?.back, "still the right card")
        XCTAssertEqual(store.card(cards[1].id, in: id)?.back, "b2")
    }

    // MARK: Reorder

    func testMoveCardsReordersLikeListOnMove() throws {
        let (store, id) = try makeStore()
        store.moveCards(in: id, from: IndexSet(integer: 0), to: 3) // f1 after f3
        XCTAssertEqual(store.decks[0].cards.map(\.front), ["f2", "f3", "f1", "f4"])

        store.moveCards(in: id, from: IndexSet(integer: 3), to: 0) // f4 to the front
        XCTAssertEqual(store.decks[0].cards.map(\.front), ["f4", "f2", "f3", "f1"])
    }

    func testMovingToTheSamePlaceDoesNotSave() throws {
        let (store, id) = try makeStore()
        store.moveCards(in: id, from: IndexSet(integer: 1), to: 1)
        XCTAssertNil(store.pendingSave)
    }

    func testOrderDefinesTheRotationSequence() throws {
        let (store, id) = try makeStore()
        let scheduler = CardScheduler()
        let slot0 = Date(timeIntervalSince1970: 0)
        let slot1 = Date(timeIntervalSince1970: scheduler.interval)

        XCTAssertEqual(scheduler.currentCard(in: store.decks[0], state: PlaybackState(), at: slot0)?.card.front, "f1")
        XCTAssertEqual(scheduler.currentCard(in: store.decks[0], state: PlaybackState(), at: slot1)?.card.front, "f2")

        store.moveCards(in: id, from: IndexSet(integer: 3), to: 0) // f4, f1, f2, f3
        XCTAssertEqual(scheduler.currentCard(in: store.decks[0], state: PlaybackState(), at: slot0)?.card.front, "f4")
        XCTAssertEqual(scheduler.currentCard(in: store.decks[0], state: PlaybackState(), at: slot1)?.card.front, "f1")
    }

    // MARK: Persistence

    func testCardEditsAreSaved() async throws {
        let (store, id) = try makeStore()
        let new = try XCTUnwrap(store.addCard(to: id))
        store.updateCard(new.id, in: id) { $0.front = "typed" }
        await store.pendingSave?.value

        XCTAssertEqual(storage.load()[0].cards.last?.front, "typed")
    }
}

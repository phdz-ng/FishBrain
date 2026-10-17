import XCTest

@MainActor
final class DeckManagementTests: XCTestCase {
    private var directory: URL!
    private var storage: DeckStorage!
    private var reloads = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = DeckStorage(directory: directory)
        reloads = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(_ decks: [Deck] = []) throws -> DeckStore {
        if !decks.isEmpty { try storage.save(decks) }
        return DeckStore(storage: storage, debounce: .milliseconds(10), onSaved: { [unowned self] in reloads += 1 })
    }

    // MARK: Create

    func testNewDecksGetUniqueDefaultNames() throws {
        let store = try makeStore()
        XCTAssertEqual(store.addDeck().name, "New Deck")
        XCTAssertEqual(store.addDeck().name, "New Deck 2")
        XCTAssertEqual(store.addDeck().name, "New Deck 3")
        store.renameDeck(store.decks[0].id, to: "Spanish")
        XCTAssertEqual(store.addDeck().name, "New Deck", "a freed default name is reused")
    }

    func testNewDeckIsAppendedEmptyWithTheAccentColor() throws {
        let store = try makeStore([Deck(name: "A")])
        let deck = store.addDeck()
        XCTAssertEqual(store.decks.last?.id, deck.id)
        XCTAssertEqual(deck.cards, [])
        XCTAssertEqual(deck.color, .accent)
    }

    // MARK: Rename

    func testRenameTrimsWhitespace() throws {
        let store = try makeStore([Deck(name: "Old")])
        XCTAssertTrue(store.renameDeck(store.decks[0].id, to: "  Spanish \n"))
        XCTAssertEqual(store.decks[0].name, "Spanish")
    }

    func testBlankOrUnknownRenameIsRejectedAndChangesNothing() throws {
        let store = try makeStore([Deck(name: "Keep")])
        XCTAssertFalse(store.renameDeck(store.decks[0].id, to: "   "))
        XCTAssertFalse(store.renameDeck(UUID(), to: "Other"))
        XCTAssertEqual(store.decks.map(\.name), ["Keep"])
    }

    // MARK: Color

    func testSetColorChangesOnlyThatDeck() throws {
        let store = try makeStore([Deck(name: "A"), Deck(name: "B")])
        store.setColor(.orange, for: store.decks[1].id)
        XCTAssertEqual(store.decks.map(\.color), [.accent, .orange])
    }

    func testSettingTheSameColorDoesNotSave() async throws {
        let store = try makeStore([Deck(name: "A", color: .green)])
        store.setColor(.green, for: store.decks[0].id)
        XCTAssertNil(store.pendingSave)
    }

    // MARK: Delete

    func testDeleteRemovesTheDeckAndItsCardsAndReturnsIt() throws {
        let cards = [Card(front: "a", back: "b"), Card(front: "c", back: "d")]
        let store = try makeStore([Deck(name: "A"), Deck(name: "B", cards: cards), Deck(name: "C")])
        let removed = store.deleteDeck(store.decks[1].id)

        XCTAssertEqual(removed?.cards.count, 2)
        XCTAssertEqual(store.decks.map(\.name), ["A", "C"])
    }

    func testDeletingAnUnknownDeckDoesNothing() throws {
        let store = try makeStore([Deck(name: "A")])
        XCTAssertNil(store.deleteDeck(UUID()))
        XCTAssertEqual(store.decks.count, 1)
        XCTAssertNil(store.pendingSave)
    }

    func testDeleteConfirmationStatesTheCardCount() {
        XCTAssertEqual(DeckSummary.deleteConfirmation(cardCount: 32), "All 32 cards in it will be removed too. This can't be undone.")
        XCTAssertEqual(DeckSummary.deleteConfirmation(cardCount: 1), "The 1 card in it will be removed too. This can't be undone.")
        XCTAssertEqual(DeckSummary.deleteConfirmation(cardCount: 0), "This deck has no cards. This can't be undone.")
    }

    func testSurfacesShowingADeletedDeckFallBackToTheFirstDeck() throws {
        let store = try makeStore([Deck(name: "First"), Deck(name: "Second"), Deck(name: "Third")])
        let shown = store.decks[2].id
        XCTAssertEqual(DeckSelection.resolve(shown, in: store.decks)?.name, "Third")

        store.deleteDeck(shown)
        XCTAssertEqual(DeckSelection.resolve(shown, in: store.decks)?.name, "First")

        store.deleteDeck(store.decks[0].id)
        store.deleteDeck(store.decks[0].id)
        XCTAssertNil(DeckSelection.resolve(shown, in: store.decks), "no decks left means nothing to show")
    }

    // MARK: Persistence

    func testEditsAreSavedAndReloadTheWidget() async throws {
        let store = try makeStore()
        let deck = store.addDeck()
        store.renameDeck(deck.id, to: "Spanish")
        store.setColor(.purple, for: deck.id)
        await store.pendingSave?.value

        let saved = storage.load()
        XCTAssertEqual(saved.map(\.name), ["Spanish"])
        XCTAssertEqual(saved.first?.color, .purple)
        XCTAssertEqual(reloads, 1, "the three quick edits coalesce into one save")

        store.deleteDeck(deck.id)
        await store.pendingSave?.value
        XCTAssertEqual(storage.load(), [])
        XCTAssertEqual(reloads, 2)
    }
}

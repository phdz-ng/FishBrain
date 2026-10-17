import XCTest

final class WidgetDeckChoiceTests: XCTestCase {
    private let spanish = Deck(name: "Spanish", cards: [Card(front: "s1", back: "x"), Card(front: "s2", back: "x")])
    private let biology = Deck(name: "Biology", cards: [Card(front: "b1", back: "x")])
    private let capitals = Deck(name: "Capitals", cards: [Card(front: "c1", back: "x")])
    private var decks: [Deck] { [spanish, biology, capitals] }
    private let now = Date(timeIntervalSince1970: 0)

    private func shown(_ deckID: Deck.ID?, in decks: [Deck]? = nil) -> String? {
        FishBrainEntry.make(decks: decks ?? self.decks, playback: [:], accent: .indigo, at: now, deckID: deckID).showing?.deckName
    }

    // MARK: Which deck a widget shows

    func testShowsTheChosenDeck() {
        XCTAssertEqual(shown(biology.id), "Biology")
        XCTAssertEqual(shown(capitals.id), "Capitals")
    }

    func testNoChoiceShowsTheFirstDeck() {
        XCTAssertEqual(shown(nil), "Spanish")
    }

    func testADeletedChoiceFallsBackToTheFirstDeck() {
        let afterDeletingBiology = [spanish, capitals]
        XCTAssertEqual(shown(biology.id, in: afterDeletingBiology), "Spanish")
        XCTAssertEqual(shown(spanish.id, in: [biology, capitals]), "Biology", "first deck of what remains")
    }

    func testDeletingEveryDeckLeavesNothingToShow() {
        XCTAssertNil(shown(biology.id, in: []))
    }

    func testEachWidgetInstanceKeepsItsOwnDeck() {
        // Two placed widgets differ only by their configured deck id.
        let first = FishBrainEntry.make(decks: decks, playback: [:], accent: .indigo, at: now, deckID: spanish.id)
        let second = FishBrainEntry.make(decks: decks, playback: [:], accent: .indigo, at: now, deckID: capitals.id)
        XCTAssertEqual(first.showing?.deckName, "Spanish")
        XCTAssertEqual(second.showing?.deckName, "Capitals")
    }

    func testChosenDeckUsesItsOwnPlaybackState() {
        let scheduler = CardScheduler()
        var skipped = PlaybackState()
        skipped = scheduler.skipping(skipped, in: spanish, at: now)
        let entry = FishBrainEntry.make(decks: decks, playback: [spanish.id: skipped], accent: .indigo, at: now, deckID: spanish.id)
        let other = FishBrainEntry.make(decks: decks, playback: [spanish.id: skipped], accent: .indigo, at: now, deckID: biology.id)

        XCTAssertEqual(entry.showing?.card.front, "s2", "the skip applies to the deck it was made in")
        XCTAssertEqual(other.showing?.card.front, "b1", "other decks are unaffected")
    }

    func testRenamingADeckShowsTheNewNameInAPlacedWidget() {
        var renamed = spanish
        renamed.name = "Español"
        XCTAssertEqual(shown(spanish.id, in: [renamed, biology]), "Español", "the widget keeps only the id")
    }

    // MARK: The picker's list

    func testPickerListsAllDecksInLibraryOrder() {
        XCTAssertEqual(DeckEntity.all(in: decks).map(\.name), ["Spanish", "Biology", "Capitals"])
        XCTAssertEqual(DeckEntity.all(in: decks).map(\.id), decks.map(\.id))
        XCTAssertEqual(DeckEntity.all(in: []).count, 0)
    }

    func testLookupDropsDeletedDecks() {
        let result = DeckEntity.matching([capitals.id, UUID(), spanish.id], in: decks)
        XCTAssertEqual(result.map(\.name), ["Spanish", "Capitals"])
        XCTAssertTrue(DeckEntity.matching([biology.id], in: [spanish]).isEmpty)
    }

    func testEntityIsIdentifiedByTheDeckID() {
        XCTAssertEqual(DeckEntity(spanish).id, spanish.id)
        XCTAssertEqual(DeckEntity(spanish).name, "Spanish")
    }
}

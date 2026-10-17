import XCTest

@MainActor
final class WidgetEmptyStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 0)
    private let spanish = Deck(name: "Spanish", cards: [Card(front: "hola", back: "hello")])
    private let empty = Deck(name: "Empty Deck")

    private func entry(_ decks: [Deck], choose id: Deck.ID? = nil) -> FishBrainEntry {
        FishBrainEntry.make(decks: decks, playback: [:], accent: .indigo, at: now, deckID: id)
    }

    // MARK: Empty states

    func testNoDecksAsksTheUserToCreateTheirFirstDeck() {
        let e = entry([])
        XCTAssertNil(e.showing)
        XCTAssertEqual(e.emptyState, .noDecks)
        XCTAssertEqual(e.emptyState?.title, "Open FishBrain to create your first deck")
        XCTAssertNil(e.emptyState?.subtitle)
    }

    func testAnEmptyDeckTellsTheUserToAddCardsToThatDeck() {
        let e = entry([empty])
        XCTAssertNil(e.showing)
        XCTAssertEqual(e.emptyState, .emptyDeck(id: empty.id, name: "Empty Deck"))
        XCTAssertEqual(e.emptyState?.title, "Add cards to “Empty Deck”")
        XCTAssertEqual(e.emptyState?.subtitle, "Open FishBrain to add some.")
    }

    func testAChosenEmptyDeckStaysEmptyInsteadOfShowingAnotherDeck() {
        let e = entry([spanish, empty], choose: empty.id)
        XCTAssertEqual(e.emptyState, .emptyDeck(id: empty.id, name: "Empty Deck"))
    }

    func testADeletedChosenDeckFallsBackToTheFirstDeck() {
        XCTAssertEqual(entry([spanish], choose: empty.id).showing?.deckName, "Spanish")
        XCTAssertEqual(entry([empty], choose: spanish.id).emptyState, .emptyDeck(id: empty.id, name: "Empty Deck"),
                       "the first deck is empty, so that is what the widget says")
        XCTAssertEqual(entry([], choose: spanish.id).emptyState, .noDecks)
    }

    func testADeckWithCardsHasNoEmptyState() {
        let e = entry([spanish])
        XCTAssertNotNil(e.showing)
        XCTAssertNil(e.emptyState)
    }

    func testEmptyTimelinesAreASingleEntry() {
        let noDecks = FishBrainEntry.timeline(decks: [], playback: [:], accent: .indigo, at: now)
        let emptyDeck = FishBrainEntry.timeline(decks: [empty], playback: [:], accent: .indigo, at: now)
        XCTAssertEqual(noDecks.entries.count, 1)
        XCTAssertEqual(emptyDeck.entries.count, 1)
    }

    // MARK: Gallery and placeholder

    func testGalleryAlwaysShowsARealisticSampleCard() {
        let gallery = FishBrainEntry.gallery(accent: .teal)
        XCTAssertNil(gallery.emptyState)
        XCTAssertEqual(gallery.accent, .teal)
        XCTAssertEqual(gallery.showing?.deckName, "Everyday Spanish")
        XCTAssertEqual(gallery.showing?.card.front, "la sobremesa")
        XCTAssertEqual(gallery.showing?.card.back, "lingering at the table after a meal")
        XCTAssertEqual(gallery.showing?.total, 48)
        XCTAssertEqual(gallery.showing?.isFlipped, false)
    }

    func testPlaceholderHasContentForWidgetKitToRedact() {
        XCTAssertNotNil(FishBrainEntry.sample.showing)
    }

    // MARK: Tapping outside the buttons

    func testTappingOpensTheAppOnTheDeckOnShow() {
        XCTAssertEqual(entry([spanish]).openURL, DeepLink.deck(spanish.id))
        XCTAssertEqual(entry([spanish, empty], choose: empty.id).openURL, DeepLink.deck(empty.id), "empty decks too")
    }

    func testTappingWithNoDecksJustOpensTheApp() {
        XCTAssertEqual(entry([]).openURL, DeepLink.app)
    }
}

@MainActor
final class DeepLinkTests: XCTestCase {
    func testDeckLinksRoundTrip() {
        let id = UUID()
        XCTAssertEqual(DeepLink.deckID(from: DeepLink.deck(id)), id)
        XCTAssertEqual(DeepLink.deck(id).absoluteString, "fishbrain://deck/\(id.uuidString)")
    }

    func testOtherLinksAreNotDeckLinks() {
        XCTAssertNil(DeepLink.deckID(from: DeepLink.app))
        XCTAssertNil(DeepLink.deckID(from: URL(string: "https://deck/\(UUID().uuidString)")!))
        XCTAssertNil(DeepLink.deckID(from: URL(string: "fishbrain://deck/not-a-uuid")!))
        XCTAssertNil(DeepLink.deckID(from: URL(string: "fishbrain://other/\(UUID().uuidString)")!))
        XCTAssertNil(DeepLink.deckID(from: URL(string: "fishbrain://deck")!))
    }

    func testRouterPassesDeckLinksToTheWindow() {
        let router = DeepLinkRouter()
        let id = UUID()
        XCTAssertTrue(router.handle(DeepLink.deck(id)))
        XCTAssertEqual(router.pendingDeckID, id)
    }

    func testRouterAcceptsTheAppLinkWithoutSwitchingDecks() {
        let router = DeepLinkRouter()
        XCTAssertTrue(router.handle(DeepLink.app))
        XCTAssertNil(router.pendingDeckID)
    }

    func testRouterIgnoresForeignLinks() {
        let router = DeepLinkRouter()
        XCTAssertFalse(router.handle(URL(string: "https://example.com")!))
        XCTAssertNil(router.pendingDeckID)
    }
}

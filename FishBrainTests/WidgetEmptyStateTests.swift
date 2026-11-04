import FishBrainIntents
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

    // MARK: A deleted deck (FLAS-109)

    func testNeverChosenShowsTheFirstDeck() {
        XCTAssertEqual(entry([spanish, empty]).showing?.deckName, "Spanish")
    }

    func testChosenAndPresentShowsThatDeck() {
        let biology = Deck(name: "Biology", cards: [Card(front: "cell", back: "x")])
        XCTAssertEqual(entry([spanish, biology], choose: biology.id).showing?.deckName, "Biology")
    }

    func testADeletedChosenDeckSaysSoInsteadOfShowingAnotherDeck() {
        let e = entry([spanish], choose: empty.id)
        XCTAssertNil(e.showing, "no silent fallback to the first deck")
        XCTAssertEqual(e.emptyState, .deckDeleted)
        XCTAssertEqual(e.emptyState?.title, "This deck was deleted")
        XCTAssertEqual(e.emptyState?.subtitle, "Right-click and choose Edit Widget to pick another.")
        XCTAssertEqual(entry([empty], choose: spanish.id).emptyState, .deckDeleted, "whatever the remaining decks hold")
    }

    func testWithNoDecksLeftTheWidgetAsksForAFirstDeck() {
        XCTAssertEqual(entry([], choose: spanish.id).emptyState, .noDecks)
    }

    func testTappingADeletedDecksWidgetJustOpensTheApp() {
        XCTAssertEqual(entry([spanish], choose: empty.id).openURL, DeepLink.app)
    }

    func testADeletedDecksTimelineIsASingleEntry() {
        let timeline = FishBrainEntry.timeline(decks: [spanish], playback: [:], accent: .indigo, at: now, deckID: empty.id)
        XCTAssertEqual(timeline.entries.map(\.emptyState), [.deckDeleted])
    }

    func testChoosingAnotherDeckBringsTheWidgetBack() {
        XCTAssertEqual(entry([spanish], choose: empty.id).emptyState, .deckDeleted)
        XCTAssertEqual(entry([spanish], choose: spanish.id).showing?.deckName, "Spanish", "the next timeline shows it")
    }

    func testTheQueryKeepsADeletedDecksIDSoTheWidgetCanTellItApart() {
        // What WidgetKit hands the timeline provider: the stored id, resolved by `DeckEntityQuery`.
        let resolved = DeckEntity.resolving([empty.id, spanish.id], in: [spanish])
        XCTAssertEqual(resolved.map(\.id), [empty.id, spanish.id])
        XCTAssertEqual(resolved.map(\.isDeleted), [true, false])
        XCTAssertEqual(resolved.first?.name, "Deleted deck")
        XCTAssertEqual(entry([spanish], choose: resolved.first?.id).emptyState, .deckDeleted)
        XCTAssertEqual(entry([spanish], choose: resolved.last?.id).showing?.deckName, "Spanish")
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

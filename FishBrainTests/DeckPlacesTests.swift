import XCTest

/// FLAS-107: which decks are in the notch and on widgets.
final class DeckPlacesTests: XCTestCase {
    private let spanish = Deck(name: "Everyday Spanish", cards: [Card(front: "a", back: "b")])
    private let biology = Deck(name: "Biology")
    private let capitals = Deck(name: "Capitals")
    private var decks: [Deck] { [spanish, biology, capitals] }

    // MARK: Counting widgets

    func testAWidgetNobodySetUpCountsForTheFirstDeck() {
        XCTAssertEqual(DeckPlaces.widgetCounts(chosen: [nil], decks: decks), [spanish.id: 1])
    }

    func testAWidgetWhoseDeckWasDeletedCountsForNothing() {
        XCTAssertEqual(DeckPlaces.widgetCounts(chosen: [UUID()], decks: decks), [:])
    }

    func testTwoWidgetsOnOneDeckCountTwice() {
        let counts = DeckPlaces.widgetCounts(chosen: [biology.id, biology.id, capitals.id, nil], decks: decks)
        XCTAssertEqual(counts, [biology.id: 2, capitals.id: 1, spanish.id: 1])
    }

    func testUnreadableWidgetSettingsCountNothing() {
        XCTAssertEqual(DeckPlaces.widgetCounts(chosen: nil, decks: decks), [:])
        XCTAssertEqual(DeckPlaces.widgetCounts(chosen: [], decks: decks), [:])
        XCTAssertEqual(DeckPlaces.widgetCounts(chosen: [nil], decks: []), [:], "no decks, nothing to show")
    }

    // MARK: Badges and words

    func testTooltipAndVoiceOverWordsForEachCase() {
        XCTAssertNil(DeckPlaces.none.tooltip)
        XCTAssertNil(DeckPlaces.none.phrase)
        XCTAssertEqual(DeckPlaces(inNotch: true).tooltip, "In the notch")
        XCTAssertEqual(DeckPlaces(widgets: 1).tooltip, "In 1 widget")
        XCTAssertEqual(DeckPlaces(widgets: 2).tooltip, "In 2 widgets")
        XCTAssertEqual(DeckPlaces(inNotch: true, widgets: 2).tooltip, "In the notch and 2 widgets")
        XCTAssertEqual(DeckPlaces(inNotch: true, widgets: 2).phrase, "in the notch and 2 widgets")
    }

    func testTheRowsVoiceOverLabelAddsWhereTheDeckIsPlaying() {
        let places = DeckPlaces(inNotch: true, widgets: 2)
        XCTAssertEqual(
            SidebarRow.accessibilityText(name: "Everyday Spanish", count: 32, detail: places.phrase),
            "Everyday Spanish, 32 cards, in the notch and 2 widgets"
        )
        XCTAssertEqual(SidebarRow.accessibilityText(name: "Biology", count: 1, detail: DeckPlaces.none.phrase), "Biology, 1 card")
    }

    // MARK: Every deck's places

    private func places(widgets: [Deck.ID?]?, showsNotch: Bool = true, notch: Deck.ID? = nil, session: Deck.ID? = nil) -> [Deck.ID: DeckPlaces] {
        DeckPlaces.all(decks: decks, chosenByWidgets: widgets, showsNotch: showsNotch, notchDeckID: notch, sessionDeckID: session)
    }

    func testTheNotchBadgeGoesOnTheNotchsDeckWhileShowInNotchIsOn() {
        XCTAssertEqual(places(widgets: [], notch: biology.id), [biology.id: DeckPlaces(inNotch: true)])
        XCTAssertEqual(places(widgets: []), [spanish.id: DeckPlaces(inNotch: true)], "no choice is the first deck")
        XCTAssertEqual(places(widgets: [], showsNotch: false, notch: biology.id), [:])
    }

    func testDuringASessionTheNotchBadgeIsOnTheSessionsDeck() {
        XCTAssertEqual(places(widgets: [], notch: biology.id, session: capitals.id), [capitals.id: DeckPlaces(inNotch: true)])
    }

    func testWithoutWidgetSettingsTheNotchBadgeStillShows() {
        XCTAssertEqual(places(widgets: nil, notch: biology.id), [biology.id: DeckPlaces(inNotch: true)])
    }

    func testNotchAndWidgetsTogether() {
        XCTAssertEqual(places(widgets: [biology.id, biology.id], notch: biology.id), [biology.id: DeckPlaces(inNotch: true, widgets: 2)])
    }
}

@MainActor
final class DeckPlacesStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    struct Failure: Error {}

    func testCountsAreReadFromWidgetKit() async {
        let id = UUID()
        let store = WidgetDeckCountStore(load: { [id, nil] })
        XCTAssertNil(store.chosen)
        store.refresh()
        await store.settle()
        XCTAssertEqual(store.chosen, [id, nil])
    }

    func testAFailedReadShowsNoWidgetBadges() async {
        let store = WidgetDeckCountStore(load: { throw Failure() })
        store.refresh()
        await store.settle()
        XCTAssertNil(store.chosen)
    }

    func testShowInNotchTurnsTheNotchOnAndSetsTheDeck() {
        let settings = SettingsStore(storage: SettingsStorage(directory: directory), onSaved: {})
        let first = Deck(name: "First"), second = Deck(name: "Second")
        settings.showsNotch = false
        XCTAssertFalse(settings.isShowingInNotch(first.id, decks: [first, second]), "off, nothing is in the notch")

        settings.showInNotch(second.id)
        XCTAssertTrue(settings.showsNotch)
        XCTAssertEqual(settings.notchDeckID, second.id)
        XCTAssertTrue(settings.isShowingInNotch(second.id, decks: [first, second]), "the menu now reads Showing in Notch")
        XCTAssertFalse(settings.isShowingInNotch(first.id, decks: [first, second]))
    }

    func testWidgetsHelpIsTheWelcomeWidgetStepWithOneLineForTheDeck() {
        let help = Welcome.widgetHelp()
        XCTAssertEqual(help.count, 1)
        XCTAssertEqual(help.first?.title, Welcome.steps(hasGettingStartedDeck: false).first?.title)
        XCTAssertEqual(help.first?.detail.hasSuffix("To show this deck, right-click the widget and choose Edit Widget."), true)
    }
}

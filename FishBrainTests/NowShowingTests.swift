import XCTest

final class NowShowingTests: XCTestCase {
    private let scheduler = CardScheduler()
    private let cards = (1...48).map { Card(front: "front \($0)", back: "back \($0)") }
    private var deck: Deck { Deck(name: "Everyday Spanish", cards: cards) }

    private func at(slot: Int, plus seconds: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: Double(slot) * scheduler.interval + seconds)
    }

    private func showing(_ state: PlaybackState = PlaybackState(), slot: Int, plus: TimeInterval = 0, deck: Deck? = nil) -> NowShowing? {
        NowShowing.make(deck: deck ?? self.deck, state: state, at: at(slot: slot, plus: plus))
    }

    func testShowsDeckNamePositionAndCurrentCard() throws {
        let now = try XCTUnwrap(showing(slot: 11)) // slot 11 -> index 11 -> card 12
        XCTAssertEqual(now.deckName, "Everyday Spanish")
        XCTAssertEqual(now.positionText, "12/48")
        XCTAssertEqual(now.card.front, "front 12")
        XCTAssertFalse(now.isFlipped)
    }

    func testCountdownAndProgressAtKeyMoments() throws {
        let start = try XCTUnwrap(showing(slot: 0))
        XCTAssertEqual(start.countdownText, "5:00")
        XCTAssertEqual(start.progress, 0, accuracy: 0.0001)

        let mid = try XCTUnwrap(showing(slot: 0, plus: 186)) // 114 s left, like the design
        XCTAssertEqual(mid.countdownText, "1:54")
        XCTAssertEqual(mid.progress, 0.62, accuracy: 0.0001)

        let end = try XCTUnwrap(showing(slot: 0, plus: 299.4))
        XCTAssertEqual(end.countdownText, "0:01", "never shows 0:00; the card changes instead")
        XCTAssertGreaterThan(end.progress, 0.99)
    }

    func testRollsOverToTheNextCardWithAFullCountdown() throws {
        let last = try XCTUnwrap(showing(slot: 0, plus: 299.9))
        let next = try XCTUnwrap(showing(slot: 1))
        XCTAssertEqual(last.card.front, "front 1")
        XCTAssertEqual(next.card.front, "front 2")
        XCTAssertEqual(next.countdownText, "5:00")
    }

    func testSkipUpdatesTheCardImmediately() throws {
        let t = at(slot: 3, plus: 40)
        let before = try XCTUnwrap(NowShowing.make(deck: deck, state: PlaybackState(), at: t))
        let skipped = scheduler.skipping(PlaybackState(), in: deck, at: t)
        let after = try XCTUnwrap(NowShowing.make(deck: deck, state: skipped, at: t))

        XCTAssertEqual(before.position, 4)
        XCTAssertEqual(after.position, 5)
        XCTAssertEqual(after.countdownText, before.countdownText, "skipping doesn't reset the timer")
    }

    func testFlipShowsTheBack() throws {
        let t = at(slot: 0, plus: 10)
        let flipped = scheduler.flipping(PlaybackState(), in: deck, at: t)
        XCTAssertEqual(NowShowing.make(deck: deck, state: flipped, at: t)?.isFlipped, true)
    }

    func testEditsShowUpImmediately() throws {
        var edited = deck
        edited.cards[0].front = "edited"
        edited.cards.append(Card(front: "new", back: "new"))

        let now = try XCTUnwrap(showing(slot: 0, deck: edited))
        XCTAssertEqual(now.card.front, "edited")
        XCTAssertEqual(now.positionText, "1/49")
    }

    func testEmptyDeckHasNothingToShow() {
        XCTAssertNil(showing(slot: 0, deck: Deck(name: "Empty")))
    }

    func testCountdownFormatting() {
        XCTAssertEqual(NowShowing.format(seconds: 300), "5:00")
        XCTAssertEqual(NowShowing.format(seconds: 114), "1:54")
        XCTAssertEqual(NowShowing.format(seconds: 9), "0:09")
        XCTAssertEqual(NowShowing.format(seconds: -4), "0:00")
    }
}

@MainActor
final class PlaybackStoreTests: XCTestCase {
    private var directory: URL!
    private var storage: PlaybackStorage!
    private var reloads = 0
    private let deck = Deck(name: "D", cards: (1...3).map { Card(front: "f\($0)", back: "b\($0)") })
    private let t = Date(timeIntervalSince1970: 100)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = PlaybackStorage(directory: directory)
        reloads = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> PlaybackStore {
        PlaybackStore(storage: storage, onSaved: { [unowned self] in reloads += 1 })
    }

    func testSkipAndFlipPersistAndReloadWidgets() {
        let store = makeStore()
        store.skip(deck, at: t)
        store.flip(deck, at: t)

        XCTAssertEqual(store.state(for: deck.id).skipOffset, 1)
        XCTAssertNotNil(store.state(for: deck.id).flip)
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(makeStore().state(for: deck.id), store.state(for: deck.id), "survives a relaunch")
    }

    func testSkippingAnEmptyDeckDoesNothing() {
        let store = makeStore()
        store.skip(Deck(name: "Empty"), at: t)
        XCTAssertEqual(reloads, 0)
        XCTAssertTrue(store.states.isEmpty)
    }

    func testDecksHaveIndependentState() {
        let other = Deck(name: "Other", cards: [Card(front: "x", back: "y")])
        let store = makeStore()
        store.skip(deck, at: t)
        XCTAssertEqual(store.state(for: other.id), PlaybackState())
    }

    func testRefreshPicksUpAnotherProcessesWrite() throws {
        let app = makeStore()
        // The widget or notch writes through its own storage instance.
        var external = PlaybackState()
        external.skipOffset = 4
        try storage.save([deck.id: external])
        // File timestamps can tie within a test; make the change observable.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: storage.fileURL.path)

        app.refresh()
        XCTAssertEqual(app.state(for: deck.id).skipOffset, 4)
    }

    func testMissingOrCorruptFileMeansFreshState() throws {
        XCTAssertTrue(makeStore().states.isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: storage.fileURL)
        XCTAssertTrue(makeStore().states.isEmpty)
    }

    func testStorageRoundTripKeepsDeckIDsAndFlips() throws {
        let scheduler = CardScheduler()
        let state = scheduler.flipping(scheduler.skipping(PlaybackState(), in: deck, at: t), in: deck, at: t)
        try storage.save([deck.id: state])
        XCTAssertEqual(storage.load(), [deck.id: state])
    }
}

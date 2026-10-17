import XCTest

final class PlaybackActionsTests: XCTestCase {
    private var directory: URL!
    private var playback: PlaybackStorage!
    private var decks: DeckStorage!
    private let spanish = Deck(name: "Spanish", cards: (1...5).map { Card(front: "s\($0)", back: "answer s\($0)") })
    private let biology = Deck(name: "Biology", cards: (1...5).map { Card(front: "b\($0)", back: "answer b\($0)") })
    private let t = Date(timeIntervalSince1970: 100) // slot 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        playback = PlaybackStorage(directory: directory)
        decks = DeckStorage(directory: directory)
        try decks.save([spanish, biology])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(_ deck: Deck, at date: Date? = nil) -> FishBrainEntry {
        FishBrainEntry.make(decks: [deck], playback: playback.load(), accent: .indigo, at: date ?? t)
    }

    // MARK: Flip

    func testFlipTogglesAndASecondClickFlipsBack() throws {
        XCTAssertEqual(entry(spanish).showing?.isFlipped, false)

        try PlaybackActions.flip(spanish, in: playback, at: t)
        XCTAssertEqual(entry(spanish).showing?.isFlipped, true)

        try PlaybackActions.flip(spanish, in: playback, at: t)
        XCTAssertEqual(entry(spanish).showing?.isFlipped, false)
    }

    func testFlipOnlyAffectsThatDeck() throws {
        try PlaybackActions.flip(spanish, in: playback, at: t)
        XCTAssertEqual(entry(biology).showing?.isFlipped, false)
    }

    func testAFlipLastsOnlyForTheCurrentCard() throws {
        try PlaybackActions.flip(spanish, in: playback, at: t)
        let nextSlot = Date(timeIntervalSince1970: CardScheduler.defaultInterval + 1)
        XCTAssertEqual(entry(spanish, at: nextSlot).showing?.isFlipped, false)
    }

    // MARK: Skip

    func testSkipMovesToTheNextCardImmediatelyFrontSideUp() throws {
        XCTAssertEqual(entry(spanish).showing?.card.front, "s1")
        try PlaybackActions.flip(spanish, in: playback, at: t)

        try PlaybackActions.skip(spanish, in: playback, at: t)
        let after = entry(spanish)
        XCTAssertEqual(after.showing?.card.front, "s2")
        XCTAssertEqual(after.showing?.isFlipped, false)
    }

    func testRepeatedSkipsKeepAdvancingAndWrap() throws {
        for _ in 0..<5 { try PlaybackActions.skip(spanish, in: playback, at: t) }
        XCTAssertEqual(entry(spanish).showing?.card.front, "s1")
    }

    func testActionsOnAnEmptyDeckDoNothing() throws {
        let empty = Deck(name: "Empty")
        try PlaybackActions.flip(empty, in: playback, at: t)
        try PlaybackActions.skip(empty, in: playback, at: t)
        XCTAssertTrue(playback.load().isEmpty)
    }

    // MARK: What the widget buttons run

    func testPerformResolvesTheDeckFromItsID() throws {
        XCTAssertTrue(try PlaybackActions.perform(.skip, deckID: biology.id.uuidString, decks: decks, playback: playback, at: t))
        XCTAssertEqual(entry(biology).showing?.card.front, "b2")
        XCTAssertEqual(entry(spanish).showing?.card.front, "s1")

        XCTAssertTrue(try PlaybackActions.perform(.flip, deckID: biology.id.uuidString, decks: decks, playback: playback, at: t))
        XCTAssertEqual(entry(biology).showing?.isFlipped, true)
    }

    func testAButtonForADeletedOrUnknownDeckIsANoOp() throws {
        try decks.save([spanish])
        XCTAssertFalse(try PlaybackActions.perform(.skip, deckID: biology.id.uuidString, decks: decks, playback: playback, at: t))
        XCTAssertFalse(try PlaybackActions.perform(.flip, deckID: "not a uuid", decks: decks, playback: playback, at: t))
        XCTAssertTrue(playback.load().isEmpty)
    }

    func testIntentsCarryTheDeckID() {
        XCTAssertEqual(FlipCardIntent(deckID: spanish.id).deckID, spanish.id.uuidString)
        XCTAssertEqual(SkipCardIntent(deckID: spanish.id).deckID, spanish.id.uuidString)
    }

    // MARK: Widget, app and notch share state

    @MainActor
    func testAFlipInTheWidgetShowsUpInTheAppAndViceVersa() throws {
        let app = PlaybackStore(storage: playback, onSaved: {})

        try PlaybackActions.perform(.flip, deckID: spanish.id.uuidString, decks: decks, playback: playback, at: t)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: playback.fileURL.path)
        app.refresh()
        XCTAssertEqual(app.state(for: spanish.id).flip != nil, true, "widget flip reaches the app within a refresh tick")

        app.flip(spanish, at: t) // flipped back in the app
        XCTAssertEqual(entry(spanish).showing?.isFlipped, false, "and the widget's next render sees it")
    }

    @MainActor
    func testAStaleAppCopyDoesNotOverwriteAWidgetSkip() throws {
        let app = PlaybackStore(storage: playback, onSaved: {}) // loads an empty state

        // The widget skips Spanish behind the app's back...
        try PlaybackActions.perform(.skip, deckID: spanish.id.uuidString, decks: decks, playback: playback, at: t)
        // ...then the app, still holding its old copy, skips Biology.
        app.skip(biology, at: t)

        let onDisk = playback.load()
        XCTAssertEqual(onDisk[spanish.id]?.skipOffset, 1, "the widget's skip survived")
        XCTAssertEqual(onDisk[biology.id]?.skipOffset, 1)
        XCTAssertEqual(app.state(for: spanish.id).skipOffset, 1, "the app picked up the widget's change too")
    }

    // MARK: Locked read-modify-write

    func testConcurrentChangesNeverLoseAnUpdate() throws {
        let storage = playback!
        let deckID = spanish.id
        DispatchQueue.concurrentPerform(iterations: 60) { _ in
            try? storage.modify { states in
                var state = states[deckID] ?? PlaybackState()
                state.skipOffset += 1
                states[deckID] = state
            }
        }
        XCTAssertEqual(storage.load()[deckID]?.skipOffset, 60)
    }

    func testNothingIsWrittenWhenNothingChanged() throws {
        try playback.modify { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: playback.fileURL.path))
    }
}

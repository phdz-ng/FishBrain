import XCTest

/// Grading cards and scheduling reviews (FLAS-41).
final class ReviewSchedulerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let minute = ReviewScheduler.minute
    private let day = ReviewScheduler.day

    // MARK: A new card

    func testANewCardOffersOneMinuteTenMinutesOneDayFourDays() {
        let new = GradeIntervals.forNewCard
        XCTAssertEqual(new.again, minute)
        XCTAssertEqual(new.hard, 10 * minute)
        XCTAssertEqual(new.good, day)
        XCTAssertEqual(new.easy, 4 * day)
        XCTAssertEqual(ReviewGrade.allCases.map(new.label), ["1 min", "10 min", "1 day", "4 days"])
    }

    func testGradingANewCard() {
        let again = ReviewScheduler.graded(nil, .again, at: now)
        XCTAssertEqual(again.due, now.addingTimeInterval(minute))
        XCTAssertEqual(again.reps, 0)
        XCTAssertEqual(again.lapses, 0, "a card that was never learned hasn't been forgotten")

        let good = ReviewScheduler.graded(nil, .good, at: now)
        XCTAssertEqual(good.due, now.addingTimeInterval(day))
        XCTAssertEqual(good.reps, 1, "graduated")
        XCTAssertEqual(good.ease, ReviewScheduler.startingEase)
        XCTAssertEqual(good.lastReviewed, now)

        let easy = ReviewScheduler.graded(nil, .easy, at: now)
        XCTAssertEqual(easy.due, now.addingTimeInterval(4 * day))
        XCTAssertEqual(easy.reps, 1)

        XCTAssertEqual(ReviewScheduler.graded(nil, .hard, at: now).reps, 0, "Hard doesn't graduate it")
    }

    // MARK: A card being reviewed

    private func graduated(interval days: Double, ease: Double = 2.5) -> ReviewState {
        ReviewState(due: now, interval: days * day, ease: ease, reps: 3, lapses: 0, lastReviewed: now.addingTimeInterval(-days * day))
    }

    func testGoodMultipliesTheGapByTheEase() {
        let next = ReviewScheduler.graded(graduated(interval: 4), .good, at: now)
        XCTAssertEqual(next.interval, 10 * day, accuracy: 1)
        XCTAssertEqual(next.reps, 4)
        XCTAssertEqual(next.ease, 2.5)
    }

    func testHardGrowsItALittleAndLowersTheEase() {
        let next = ReviewScheduler.graded(graduated(interval: 10), .hard, at: now)
        XCTAssertEqual(next.interval, 12 * day, accuracy: 1)
        XCTAssertEqual(next.ease, 2.35, accuracy: 0.0001)
    }

    func testEasyGrowsItMostAndRaisesTheEase() {
        let next = ReviewScheduler.graded(graduated(interval: 10), .easy, at: now)
        XCTAssertEqual(next.interval, 10 * 2.5 * 1.3 * day, accuracy: 1)
        XCTAssertEqual(next.ease, 2.65, accuracy: 0.0001)
    }

    func testForgettingStartsItOverAndCountsALapse() {
        let next = ReviewScheduler.graded(graduated(interval: 30), .again, at: now)
        XCTAssertEqual(next.interval, minute)
        XCTAssertEqual(next.reps, 0, "back to learning")
        XCTAssertEqual(next.lapses, 1)
        XCTAssertEqual(next.ease, 2.3, accuracy: 0.0001)
        // and it graduates again with one Good
        let back = ReviewScheduler.graded(next, .good, at: now.addingTimeInterval(120))
        XCTAssertEqual(back.interval, day)
        XCTAssertEqual(back.reps, 1)
        XCTAssertEqual(back.lapses, 1, "the lapse is remembered")
    }

    func testTheEaseNeverFallsBelowItsFloor() {
        var state = graduated(interval: 5, ease: 1.35)
        for _ in 0..<5 { state = ReviewScheduler.graded(state, .hard, at: now) }
        XCTAssertGreaterThanOrEqual(state.ease, ReviewScheduler.minimumEase)
        state = graduated(interval: 5, ease: 1.35)
        state = ReviewScheduler.graded(state, .again, at: now)
        XCTAssertEqual(state.ease, ReviewScheduler.minimumEase, accuracy: 0.0001)
    }

    func testTheFourButtonsAreAlwaysInOrderAndNeverTheSameLabel() {
        for interval in stride(from: 1.0, through: 1500, by: 7) {
            for ease in [1.3, 1.8, 2.5, 3.1] {
                let i = ReviewScheduler.intervals(from: graduated(interval: interval, ease: ease))
                XCTAssertLessThan(i.again, i.hard)
                XCTAssertLessThan(i.hard, i.good, "interval \(interval) ease \(ease)")
                XCTAssertLessThanOrEqual(i.good, i.easy)
                XCTAssertLessThanOrEqual(i.easy, ReviewScheduler.maximumInterval)
            }
        }
        let early = ReviewScheduler.intervals(from: graduated(interval: 1))
        XCTAssertEqual([early.hard, early.good, early.easy].map { ReviewScheduler.label(for: $0) }.count, 3)
        XCTAssertGreaterThanOrEqual(early.good - early.hard, day, "a day apart at least")
    }

    func testTheGapIsCapped() {
        let huge = graduated(interval: 3000, ease: 3)
        XCTAssertEqual(ReviewScheduler.graded(huge, .easy, at: now).interval, ReviewScheduler.maximumInterval)
    }

    // MARK: Words

    func testLabels() {
        XCTAssertEqual(ReviewScheduler.label(for: 0), "1 min")
        XCTAssertEqual(ReviewScheduler.label(for: 60), "1 min")
        XCTAssertEqual(ReviewScheduler.label(for: 600), "10 min")
        XCTAssertEqual(ReviewScheduler.label(for: 3 * 3600), "3 h")
        XCTAssertEqual(ReviewScheduler.label(for: day), "1 day")
        XCTAssertEqual(ReviewScheduler.label(for: 4 * day), "4 days")
        XCTAssertEqual(ReviewScheduler.label(for: 29 * day), "29 days")
        XCTAssertEqual(ReviewScheduler.label(for: 60 * day), "2 mo")
        XCTAssertEqual(ReviewScheduler.label(for: 400 * day), "1 yr")
    }

    func testShortcutKeysAreOneToFour() {
        XCTAssertEqual(ReviewGrade.allCases.map(\.shortcutKey), ["1", "2", "3", "4"])
        XCTAssertEqual(ReviewGrade.allCases.map(\.displayName), ["Again", "Hard", "Good", "Easy"])
    }

    // MARK: Storage

    func testPlaybackStateWithReviewsRoundTripsAndAnOlderFileStillLoads() throws {
        var state = PlaybackState(skipOffset: 3)
        let id = UUID()
        state.reviews[id.uuidString] = ReviewScheduler.graded(nil, .good, at: now)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackState.self, from: data), state)

        let old = try JSONDecoder().decode(PlaybackState.self, from: Data(#"{"skipOffset":2}"#.utf8))
        XCTAssertEqual(old.skipOffset, 2)
        XCTAssertTrue(old.reviews.isEmpty, "nobody has graded anything yet")
    }
}

final class DueFirstRotationTests: XCTestCase {
    private let scheduler = CardScheduler()
    /// A slot boundary, so slot arithmetic is easy to read: slot 6000.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var deck: Deck!

    override func setUp() {
        deck = Deck(name: "Spanish", color: .green, cards: (0..<10).map { Card(front: "f\($0)", back: "b\($0)") })
    }

    private func review(due: Date) -> ReviewState {
        ReviewState(due: due, interval: 86_400, ease: 2.5, reps: 1, lapses: 0, lastReviewed: due.addingTimeInterval(-86_400))
    }

    private func state(due: [Int: TimeInterval], skipOffset: Int = 0) -> PlaybackState {
        var s = PlaybackState(skipOffset: skipOffset)
        for (index, offset) in due { s.reviews[deck.cards[index].id.uuidString] = review(due: t0.addingTimeInterval(offset)) }
        return s
    }

    func testNobodyWhoNeverGradesSeesAnyChange() {
        let plain = PlaybackState(skipOffset: 3)
        for slot in 0..<30 {
            let at = t0.addingTimeInterval(Double(slot) * scheduler.interval)
            let expected = ((scheduler.slot(at: at) + 3) % 10 + 10) % 10
            XCTAssertEqual(scheduler.currentCard(in: deck, state: plain, at: at)?.index, expected, "the plain rotation, as before")
        }
        XCTAssertEqual(plain.dueCards(in: deck, at: t0), [])
        XCTAssertEqual(plain.dueCount(in: deck, at: t0), 0)
    }

    func testDueCardsComeFirstTheMostOverdueFirst() {
        let s = state(due: [7: -600, 2: -3600, 5: -60])
        XCTAssertEqual(s.dueCards(in: deck, at: t0).map(\.front), ["f2", "f7", "f5"])
        XCTAssertEqual(s.dueCount(in: deck, at: t0), 3)
    }

    func testTiesKeepDeckOrder() {
        let s = state(due: [6: -100, 1: -100, 3: -100])
        XCTAssertEqual(s.dueCards(in: deck, at: t0).map(\.front), ["f1", "f3", "f6"])
    }

    func testTheShownCardRotatesAmongTheDueCardsAndKeepsItsDeckIndex() {
        let s = state(due: [7: -600, 2: -3600, 5: -60])
        let shown = (0..<4).compactMap { n in
            scheduler.currentCard(in: deck, state: s, at: t0.addingTimeInterval(Double(n) * scheduler.interval))
        }
        // The slot number shifts the starting point; what matters is they cycle through just these three.
        XCTAssertEqual(Set(shown.map(\.index)), [2, 7, 5])
        XCTAssertEqual(shown[0].index, shown[3].index, "three due cards, so every third slot repeats")
        XCTAssertEqual(shown[0].card.front, "f\(shown[0].index)", "the index is the card's place in the deck")
    }

    func testACardNotYetDueIsNotShownWhileOthersAre() {
        let s = state(due: [4: -60, 8: 3600])
        for n in 0..<6 {
            XCTAssertEqual(scheduler.currentCard(in: deck, state: s, at: t0.addingTimeInterval(Double(n) * scheduler.interval))?.index, 4)
        }
    }

    func testWithNothingDueItIsTheWholeDeckInOrderAsBefore() {
        let s = state(due: [4: 3600, 8: 7200]) // graded, but not due yet
        let plain = PlaybackState()
        for n in 0..<12 {
            let at = t0.addingTimeInterval(Double(n) * scheduler.interval)
            XCTAssertEqual(scheduler.currentCard(in: deck, state: s, at: at)?.index, scheduler.currentCard(in: deck, state: plain, at: at)?.index)
        }
    }

    func testACardThatFallsDueMidSlotWaitsForTheNextSlot() {
        // Due 2 minutes into the slot that starts at t0.
        let s = state(due: [4: 120])
        let before = scheduler.currentCard(in: deck, state: s, at: t0.addingTimeInterval(60))
        let after = scheduler.currentCard(in: deck, state: s, at: t0.addingTimeInterval(200))
        XCTAssertEqual(before?.card.id, after?.card.id, "the whole slot shows one card, on every surface")
        XCTAssertEqual(scheduler.currentCard(in: deck, state: s, at: t0.addingTimeInterval(300))?.index, 4, "and it arrives with the next slot")
    }

    func testSlotStartIsTheSlotsFirstInstant() {
        XCTAssertEqual(scheduler.slotStart(at: t0.addingTimeInterval(299)), t0)
        XCTAssertEqual(scheduler.slotStart(at: t0.addingTimeInterval(300)), t0.addingTimeInterval(300))
        let session = CardScheduler(interval: 30, origin: t0.timeIntervalSince1970 + 10)
        XCTAssertEqual(session.slotStart(at: t0.addingTimeInterval(45)), t0.addingTimeInterval(40))
    }

    func testAFlipIsPerCardAndSurvivesNothingElse() {
        let s = state(due: [3: -60])
        let flipped = scheduler.flipping(s, in: deck, at: t0)
        XCTAssertEqual(scheduler.currentCard(in: deck, state: flipped, at: t0)?.isFlipped, true)
        XCTAssertEqual(scheduler.currentCard(in: deck, state: flipped, at: t0)?.index, 3)
    }
}

final class GradingActionTests: XCTestCase {
    private var directory: URL!
    private var deck: Deck!
    private let scheduler = CardScheduler()
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        deck = Deck(name: "Spanish", color: .green, cards: (0..<5).map { Card(front: "f\($0)", back: "b\($0)") })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storage: PlaybackStorage { PlaybackStorage(directory: directory) }

    private func shown(at date: Date) -> ScheduledCard? {
        scheduler.currentCard(in: deck, state: storage.load()[deck.id] ?? PlaybackState(), at: date)
    }

    func testAnUnflippedCardCannotBeGraded() throws {
        let before = shown(at: t0)
        try PlaybackActions.grade(.good, deck, in: storage, at: t0)
        XCTAssertEqual(shown(at: t0)?.card.id, before?.card.id)
        XCTAssertTrue((storage.load()[deck.id] ?? PlaybackState()).reviews.isEmpty)
    }

    func testGradingSchedulesTheCardAndMovesToTheNext() throws {
        let first = try XCTUnwrap(shown(at: t0)).card
        try PlaybackActions.flip(deck, in: storage, at: t0)
        try PlaybackActions.grade(.good, deck, in: storage, at: t0)
        let state = try XCTUnwrap(storage.load()[deck.id])
        let review = try XCTUnwrap(state.review(for: first.id))
        XCTAssertEqual(review.due, t0.addingTimeInterval(86_400), "a new card graded Good comes back in a day")
        XCTAssertNil(state.flip, "the next card is question side up")
        XCTAssertNotEqual(shown(at: t0)?.card.id, first.id, "moved on to the next card")
        XCTAssertEqual(shown(at: t0)?.isFlipped, false)
    }

    func testAnAgainCardComesBackAfterAMinuteAndLeadsTheNextSlot() throws {
        let first = try XCTUnwrap(shown(at: t0)).card
        try PlaybackActions.flip(deck, in: storage, at: t0)
        try PlaybackActions.grade(.again, deck, in: storage, at: t0)
        // Not due for a minute, so the next 5-minute slot is the first to show it.
        let nextSlot = t0.addingTimeInterval(scheduler.interval)
        XCTAssertEqual(shown(at: nextSlot)?.card.id, first.id, "it is due by then and goes first")
    }

    func testDueCardsAreWorkedThroughInOrderAndTheDeckThenCarriesOn() throws {
        // Three graded cards, all due.
        var state = PlaybackState()
        for (i, overdue) in [(1, 3000.0), (3, 2000), (4, 1000)] {
            state.reviews[deck.cards[i].id.uuidString] = ReviewState(
                due: t0.addingTimeInterval(-overdue), interval: 86_400, ease: 2.5, reps: 1, lapses: 0, lastReviewed: t0.addingTimeInterval(-86_400 - overdue)
            )
        }
        try storage.save([deck.id: state])
        var seen: [String] = []
        for step in 0..<3 {
            let now = t0.addingTimeInterval(Double(step))
            let card = try XCTUnwrap(shown(at: now))
            seen.append(card.card.front)
            try PlaybackActions.flip(deck, in: storage, at: now)
            try PlaybackActions.grade(.good, deck, in: storage, at: now)
        }
        XCTAssertEqual(Set(seen), ["f1", "f3", "f4"], "every due card came up once")
        XCTAssertEqual((storage.load()[deck.id] ?? PlaybackState()).dueCount(in: deck, at: t0.addingTimeInterval(10)), 0)
        XCTAssertNotNil(shown(at: t0.addingTimeInterval(10)), "and the notch isn't empty: the plain rotation carries on")
    }

    func testAGradeTapRepeatedDoesNotGradeTheNextCard() throws {
        try PlaybackActions.flip(deck, in: storage, at: t0)
        try PlaybackActions.grade(.easy, deck, in: storage, at: t0)
        try PlaybackActions.grade(.easy, deck, in: storage, at: t0) // a second tap on the same button
        XCTAssertEqual((storage.load()[deck.id] ?? PlaybackState()).reviews.count, 1)
    }

    func testDeletedCardsLoseTheirSchedules() throws {
        var state = PlaybackState()
        state.reviews[UUID().uuidString] = ReviewScheduler.graded(nil, .good, at: t0) // a card that no longer exists
        try storage.save([deck.id: state])
        try PlaybackActions.flip(deck, in: storage, at: t0)
        try PlaybackActions.grade(.good, deck, in: storage, at: t0)
        XCTAssertEqual((storage.load()[deck.id] ?? PlaybackState()).reviews.count, 1, "only the graded card")
    }

    func testGradingNeverTouchesOtherDecksOrTheSkips() throws {
        let other = Deck(name: "Other", color: .purple, cards: [Card(front: "x", back: "y")])
        try PlaybackActions.skip(other, in: storage, at: t0)
        try PlaybackActions.flip(deck, in: storage, at: t0)
        try PlaybackActions.grade(.hard, deck, in: storage, at: t0)
        XCTAssertEqual(storage.load()[other.id]?.skipOffset, 1)
    }

    func testAWidgetTapGradesToo() throws {
        try DeckStorage(directory: directory).save([deck])
        let decks = DeckStorage(directory: directory)
        try PlaybackActions.perform(.flip, deckID: deck.id.uuidString, decks: decks, playback: storage, at: t0)
        XCTAssertTrue(try PlaybackActions.perform(.grade(.good), deckID: deck.id.uuidString, decks: decks, playback: storage, at: t0))
        XCTAssertEqual((storage.load()[deck.id] ?? PlaybackState()).reviews.count, 1)
        XCTAssertFalse(try PlaybackActions.perform(.grade(.good), deckID: UUID().uuidString, decks: decks, playback: storage, at: t0), "a deck that was deleted")
    }

    func testTheIntentCarriesTheDeckAndTheGrade() {
        let intent = GradeCardIntent(deckID: deck.id, grade: .easy)
        XCTAssertEqual(intent.deckID, deck.id.uuidString)
        XCTAssertEqual(ReviewGrade(rawValue: intent.grade), .easy)
    }

    func testTheButtonsShowTheCardsOwnIntervalsAndTheDueCount() throws {
        var state = PlaybackState()
        let first = try XCTUnwrap(scheduler.currentCard(in: deck, state: state, at: t0)).card
        state.reviews[first.id.uuidString] = ReviewState(due: t0.addingTimeInterval(-60), interval: 4 * 86_400, ease: 2.5, reps: 2, lapses: 0, lastReviewed: t0)
        let showing = try XCTUnwrap(NowShowing.make(deck: deck, state: state, at: t0))
        XCTAssertEqual(showing.card.id, first.id)
        XCTAssertEqual(showing.gradeIntervals.good, 10 * 86_400, accuracy: 1)
        XCTAssertEqual(showing.dueCount, 1)
        let plain = try XCTUnwrap(NowShowing.make(deck: deck, state: PlaybackState(), at: t0))
        XCTAssertEqual(plain.gradeIntervals, .forNewCard)
        XCTAssertEqual(plain.dueCount, 0)
    }

    func testTheDeckSubtitleMentionsDueCards() {
        XCTAssertEqual(DeckSummary.subtitle(cardCount: 48, widgetCount: 0, showsInNotch: true), "48 cards, showing in the notch")
        XCTAssertEqual(DeckSummary.subtitle(cardCount: 48, widgetCount: 0, showsInNotch: true, dueCount: 3), "48 cards, 3 due, showing in the notch")
        XCTAssertEqual(DeckSummary.subtitle(cardCount: 1, widgetCount: 2, showsInNotch: false, dueCount: 1), "1 card, 1 due, showing in 2 widgets")
    }
}

@MainActor
final class NotchGradingTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_030)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRig(withSessions: Bool = false) throws -> (NotchController, PlaybackStore, SessionStore) {
        let deck = Deck(name: "Spanish", color: .green, cards: (0..<10).map { Card(front: "f\($0)", back: "b\($0)") })
        try DeckStorage(directory: root).save([deck])
        let deckStore = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let sessions = SessionStore(storage: SessionStorage(directory: root), studyStorage: StudyStorage(directory: root))
        let screen = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876),
            safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, displayID: 1, isBuiltIn: true
        )
        var sessionProvider: (@MainActor () -> SessionStore)?
        if withSessions { sessionProvider = { sessions } }
        let controller = NotchController(
            placementProvider: { NotchGeometry.placement(for: screen) },
            showsPanel: false, installsMonitors: false, watchDirectory: root, clock: { self.now },
            deckStore: { deckStore }, playbackStore: { playback }, settingsStore: { settings },
            studyStore: { StudyStore(storage: StudyStorage(directory: self.root)) },
            sessionStore: sessionProvider
        )
        addTeardownBlock { controller.stop() }
        controller.start()
        return (controller, playback, sessions)
    }

    func testGradingFromTheNotchSchedulesTheCardAndShowsTheNextOne() throws {
        let (controller, playback, _) = try makeRig()
        let first = try XCTUnwrap(controller.model.showing)
        controller.model.onFlip()
        XCTAssertEqual(controller.model.showing?.isFlipped, true)
        XCTAssertTrue(controller.model.canGrade)
        controller.model.onGrade(.good)
        XCTAssertNotEqual(controller.model.showing?.card.id, first.card.id, "the next card")
        XCTAssertEqual(controller.model.showing?.isFlipped, false)
        XCTAssertEqual(playback.state(for: first.deckID).reviews.count, 1)
    }

    func testTheButtonsShowTheIntervalsForThatCard() throws {
        let (controller, _, _) = try makeRig()
        controller.model.onFlip()
        XCTAssertEqual(controller.model.showing?.gradeIntervals, .forNewCard)
        XCTAssertEqual(controller.model.showing?.gradeIntervals.label(.good), "1 day")
    }

    func testFlippingAndGradingStillCountTowardTheDailyGoalOnce() throws {
        let (controller, _, _) = try makeRig()
        controller.model.onFlip()
        controller.model.onGrade(.again)
        XCTAssertEqual(controller.model.study?.count, 1, "the flip counted; grading adds nothing")
    }

    func testGradingWaitsForTheFlipAndIsOffDuringASession() throws {
        let (controller, playback, sessions) = try makeRig(withSessions: true)
        let first = try XCTUnwrap(controller.model.showing)
        controller.model.onGrade(.good) // not turned over yet
        XCTAssertEqual(controller.model.showing?.card.id, first.card.id)

        controller.model.onStartSession(5)
        XCTAssertFalse(controller.model.canGrade, "a session has its own rotation")
        controller.model.onFlip()
        controller.model.onGrade(.good)
        XCTAssertTrue(playback.state(for: first.deckID).reviews.isEmpty)
        XCTAssertNotNil(sessions.active)
    }

    func testTheOpenPanelHasRoomForTheGradeRow() {
        XCTAssertEqual(NotchGeometry.expandedSize.height, 282)
        XCTAssertLessThanOrEqual(NotchGeometry.expandedSize.width, 420)
    }
}

final class KeyboardGradingSettingTests: XCTestCase {
    func testItIsOffByDefaultSoTheNotchNeverTakesFocusUnlessAskedTo() {
        XCTAssertFalse(AppSettings().keyboardGrading)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SettingsStorage(directory: directory)
        XCTAssertFalse(storage.load().keyboardGrading)
        try? storage.save(AppSettings(keyboardGrading: true))
        XCTAssertTrue(storage.load().keyboardGrading)
        try? Data(#"{"accent":"teal"}"#.utf8).write(to: storage.fileURL)
        XCTAssertFalse(storage.load().keyboardGrading, "an older file")
    }

    func testThePanelOnlyTakesTheKeyboardWhenToldTo() {
        let panel = NotchPanel()
        XCTAssertFalse(panel.canBecomeKey)
        panel.allowsKeyboard = true
        XCTAssertTrue(panel.canBecomeKey)
        panel.releaseKeyboard()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }
}

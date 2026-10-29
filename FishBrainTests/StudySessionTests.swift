import XCTest

/// The study session (FLAS-40).
final class StudySessionLogicTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_030) // 30 s past a slot boundary, to show origin matters
    private let deck = Deck(name: "Spanish", color: .green, cards: (1...10).map { Card(front: "f\($0)", back: "b\($0)") })

    private func started(minutes: Int = 15, index: Int = 4) -> StudySession {
        var s = StudySession()
        s.start(deckID: deck.id, currentIndex: index, minutes: minutes, at: t0)
        return s
    }

    private func card(_ s: StudySession, after seconds: TimeInterval) -> ScheduledCard? {
        guard let active = s.active else { return nil }
        return active.scheduler.currentCard(in: deck, state: active.playback, at: t0.addingTimeInterval(seconds))
    }

    // MARK: Rotation

    func testTheSessionStartsOnTheCardThatWasShowing() {
        XCTAssertEqual(card(started(index: 4), after: 0)?.index, 4)
    }

    func testCardsRotateEveryThirtySecondsFromTheMomentItStarts() {
        let s = started(index: 4)
        XCTAssertEqual(card(s, after: 29.9)?.index, 4, "the first card lasts a full 30 seconds")
        XCTAssertEqual(card(s, after: 30)?.index, 5)
        XCTAssertEqual(card(s, after: 59.9)?.index, 5)
        XCTAssertEqual(card(s, after: 60)?.index, 6)
        XCTAssertEqual(StudySession.rotationInterval, 30)
    }

    func testTheNextRotationIsThirtySecondsAfterTheStartNotOnAnEpochBoundary() {
        let s = started()
        XCTAssertEqual(s.active?.scheduler.nextRotation(after: t0), t0.addingTimeInterval(30))
        XCTAssertEqual(s.active?.scheduler.nextRotation(after: t0.addingTimeInterval(31)), t0.addingTimeInterval(60))
    }

    func testTheNormalRotationIsUnchangedByTheOriginParameter() {
        let scheduler = CardScheduler()
        XCTAssertEqual(scheduler.origin, 0)
        XCTAssertEqual(scheduler.slot(at: Date(timeIntervalSince1970: 600)), 2)
        XCTAssertEqual(scheduler.nextRotation(after: Date(timeIntervalSince1970: 610)), Date(timeIntervalSince1970: 900))
    }

    func testSkipMovesOnAtOnce() {
        var s = started(index: 4)
        s.skip(in: deck, at: t0.addingTimeInterval(5))
        XCTAssertEqual(card(s, after: 5)?.index, 5)
        XCTAssertEqual(card(s, after: 29)?.index, 5)
        XCTAssertEqual(card(s, after: 30)?.index, 6, "the 30-second rotation keeps counting from the start")
        XCTAssertEqual(card(s, after: 60)?.index, 7)
    }

    // MARK: Reviewed

    func testReviewedCountsCardsFlippedToTheAnswerOnce() {
        var s = started()
        XCTAssertNotNil(s.flip(in: deck, at: t0.addingTimeInterval(2)), "to the answer: studied")
        XCTAssertNil(s.flip(in: deck, at: t0.addingTimeInterval(3)), "back to the question")
        XCTAssertNotNil(s.flip(in: deck, at: t0.addingTimeInterval(4)), "the answer again")
        XCTAssertEqual(s.active?.reviewed, 1, "the same card counts once")
        s.skip(in: deck, at: t0.addingTimeInterval(5))
        _ = s.flip(in: deck, at: t0.addingTimeInterval(6))
        XCTAssertEqual(s.active?.reviewed, 2)
    }

    func testSkippingWithoutFlippingReviewsNothing() {
        var s = started()
        s.skip(in: deck, at: t0.addingTimeInterval(1))
        XCTAssertEqual(s.active?.reviewed, 0)
    }

    func testAFlipOnlyLastsForItsCard() {
        var s = started(index: 4)
        _ = s.flip(in: deck, at: t0.addingTimeInterval(2))
        XCTAssertEqual(card(s, after: 3)?.isFlipped, true)
        XCTAssertEqual(card(s, after: 31)?.isFlipped, false, "the next card arrives question side up")
    }

    // MARK: Time

    func testTimeLeftIsWorkedOutFromTheClock() {
        let a = started(minutes: 15).active!
        XCTAssertEqual(a.remaining(at: t0), 900)
        XCTAssertEqual(a.remaining(at: t0.addingTimeInterval(522)), 378, "6:18 left")
        XCTAssertEqual(a.remaining(at: t0.addingTimeInterval(5000)), 0, "never negative, even after a long sleep")
        XCTAssertEqual(a.progress(at: t0.addingTimeInterval(450)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(a.progress(at: t0.addingTimeInterval(5000)), 1)
        XCTAssertEqual(a.progress(at: t0.addingTimeInterval(-50)), 0)
    }

    func testOnlyTheOfferedLengthsAreAccepted() {
        XCTAssertEqual(StudySession.lengths, [5, 10, 15, 25])
        XCTAssertEqual(StudySession.defaultMinutes, 15)
        XCTAssertEqual(started(minutes: 7).active?.minutes, 15, "anything else falls back to the default")
        XCTAssertEqual(started(minutes: 25).active?.minutes, 25)
    }

    // MARK: Ending

    func testItEndsWhenTheTimeIsUpWithTheRecap() {
        var s = started(minutes: 5)
        for n in 0..<3 {
            _ = s.flip(in: deck, at: t0.addingTimeInterval(Double(n) * 30 + 1))
        }
        XCTAssertFalse(s.expireIfNeeded(at: t0.addingTimeInterval(299)))
        XCTAssertNotNil(s.active)
        XCTAssertTrue(s.expireIfNeeded(at: t0.addingTimeInterval(300)))
        XCTAssertNil(s.active)
        XCTAssertEqual(s.last?.reviewed, 3)
        XCTAssertEqual(s.last?.text, "3 cards in 5 min")
        XCTAssertEqual(s.last?.lastText, "Last: 3 cards")
        XCTAssertEqual(s.recap(at: t0.addingTimeInterval(301))?.reviewed, 3)
    }

    func testTheRecapGoesAwayAfterAFewSeconds() {
        var s = started(minutes: 5)
        s.expireIfNeeded(at: t0.addingTimeInterval(300))
        XCTAssertNotNil(s.recap(at: t0.addingTimeInterval(300 + StudySession.recapDuration - 1)))
        XCTAssertNil(s.recap(at: t0.addingTimeInterval(300 + StudySession.recapDuration)))
        XCTAssertNotNil(s.last, "but the last result is kept")
    }

    func testASessionThatEndedDuringSleepShowsItsRecapOnWake() {
        var s = started(minutes: 5)
        let wake = t0.addingTimeInterval(3 * 3600)
        XCTAssertTrue(s.expireIfNeeded(at: wake))
        XCTAssertNotNil(s.recap(at: wake.addingTimeInterval(1)), "the recap runs from the wake, not from when it ended")
        XCTAssertEqual(s.last?.minutes, 5, "and says the length that was planned")
    }

    func testEndingEarlySaysHowLongItReallyRan() {
        var s = started(minutes: 15)
        _ = s.flip(in: deck, at: t0.addingTimeInterval(5))
        s.end(at: t0.addingTimeInterval(7 * 60 + 10))
        XCTAssertEqual(s.last?.text, "1 card in 7 min")
        XCTAssertNil(s.active)
        XCTAssertNotNil(s.recap(at: t0.addingTimeInterval(7 * 60 + 11)))
    }

    func testEndingStraightAwayCountsAsOneMinuteNotZero() {
        var s = started()
        s.end(at: t0.addingTimeInterval(4))
        XCTAssertEqual(s.last?.minutes, 1)
    }

    func testEndingNeverReportsMoreThanTheLength() {
        var s = started(minutes: 5)
        s.end(at: t0.addingTimeInterval(9999))
        XCTAssertEqual(s.last?.minutes, 5)
    }

    func testStartingAgainClearsTheOldRecapAndRemembersTheLength() {
        var s = started(minutes: 10)
        s.end(at: t0.addingTimeInterval(60))
        s.start(deckID: deck.id, currentIndex: 0, minutes: 25, at: t0.addingTimeInterval(100))
        XCTAssertNil(s.recap(at: t0.addingTimeInterval(101)))
        XCTAssertEqual(s.preferredMinutes, 25)
        XCTAssertEqual(s.last?.minutes, 1, "the last result stays until this one ends")
    }

    func testTheWordsForOneCard() {
        XCTAssertEqual(StudySession.Result(reviewed: 1, minutes: 1, endedAt: t0).text, "1 card in 1 min")
        XCTAssertEqual(StudySession.Result(reviewed: 0, minutes: 5, endedAt: t0).lastText, "Last: 0 cards")
        XCTAssertEqual(StudySession.Result(reviewed: 22, minutes: 15, endedAt: t0).text, "22 cards in 15 min")
    }
}

final class SessionStorageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testASessionSurvivesARelaunch() throws {
        let storage = SessionStorage(directory: directory)
        var s = StudySession()
        let deck = Deck(name: "Spanish", color: .green, cards: (1...5).map { Card(front: "f\($0)", back: "b\($0)") })
        s.start(deckID: deck.id, currentIndex: 2, minutes: 10, at: Date(timeIntervalSince1970: 1_800_000_000))
        _ = s.flip(in: deck, at: Date(timeIntervalSince1970: 1_800_000_005))
        try storage.save(s)
        let loaded = storage.load()
        XCTAssertEqual(loaded, s)
        XCTAssertEqual(loaded.active?.reviewed, 1)
    }

    func testAMissingOrUnreadableFileMeansNoSession() throws {
        let storage = SessionStorage(directory: directory)
        XCTAssertEqual(storage.load(), StudySession())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: storage.fileURL)
        XCTAssertEqual(storage.load(), StudySession())
    }
}

@MainActor
final class SessionStoreTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let deck = Deck(name: "Spanish", color: .green, cards: (1...10).map { Card(front: "f\($0)", back: "b\($0)") })

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> SessionStore {
        SessionStore(storage: SessionStorage(directory: directory), studyStorage: StudyStorage(directory: directory))
    }

    func testChangesAreSavedAtOnceAndComeBackAfterARelaunch() {
        let store = makeStore()
        store.start(deckID: deck.id, currentIndex: 0, minutes: 10, at: now)
        XCTAssertNotNil(makeStore().active, "a new store reads the same file")
        store.end(at: now.addingTimeInterval(120))
        XCTAssertNil(makeStore().active)
        XCTAssertEqual(makeStore().session.last?.minutes, 2)
    }

    func testAFlipDuringASessionCountsTowardTheDailyGoalAndTheStreak() throws {
        try SettingsStorage(directory: directory).save(AppSettings(dailyGoal: 2))
        let store = makeStore()
        store.start(deckID: deck.id, currentIndex: 0, minutes: 5, at: now)
        store.flip(in: deck, at: now.addingTimeInterval(1))
        store.skip(in: deck, at: now.addingTimeInterval(2))
        store.flip(in: deck, at: now.addingTimeInterval(3))
        let log = StudyStorage(directory: directory).load()
        XCTAssertEqual(log.count(on: now), 2)
        XCTAssertEqual(log.streak(at: now, goal: 2), 1, "two cards met the goal of two")
        XCTAssertEqual(store.active?.reviewed, 2)
    }

    func testTheSameCardOnAnotherLapOfTheDeckCountsForTheSessionButNotTwiceForTheDay() throws {
        let small = Deck(name: "Two", color: .green, cards: [Card(front: "a", back: "b"), Card(front: "c", back: "d")])
        let store = makeStore()
        store.start(deckID: small.id, currentIndex: 0, minutes: 5, at: now)
        for n in 0..<4 {
            store.flip(in: small, at: now.addingTimeInterval(Double(n) * 30 + 1)) // a new card each 30 s, round and round
        }
        XCTAssertEqual(store.active?.reviewed, 4, "four cards reviewed in the session")
        XCTAssertEqual(StudyStorage(directory: directory).load().count(on: now), 2, "two different cards studied today")
    }

    func testTheNormalRotationFileIsNeverTouched() {
        let store = makeStore()
        store.start(deckID: deck.id, currentIndex: 0, minutes: 5, at: now)
        store.flip(in: deck, at: now.addingTimeInterval(1))
        store.skip(in: deck, at: now.addingTimeInterval(2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: PlaybackStorage(directory: directory).fileURL.path))
    }

    func testExpiringWhenTheTimeIsUpAndNotBefore() {
        let store = makeStore()
        store.start(deckID: deck.id, currentIndex: 0, minutes: 5, at: now)
        store.expireIfNeeded(at: now.addingTimeInterval(299))
        XCTAssertNotNil(store.active)
        store.expireIfNeeded(at: now.addingTimeInterval(300))
        XCTAssertNil(store.active)
    }

    func testOnlyOfferedLengthsAreRemembered() {
        let store = makeStore()
        store.setPreferredMinutes(7)
        XCTAssertEqual(store.session.preferredMinutes, 15)
        store.setPreferredMinutes(25)
        XCTAssertEqual(makeStore().session.preferredMinutes, 25)
    }
}

@MainActor
final class SessionNotchTests: XCTestCase {
    private var root: URL!
    private var now = Date(timeIntervalSince1970: 1_800_000_030)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Rig {
        var controller: NotchController
        var sessions: SessionStore
        var settings: SettingsStore
        var playback: PlaybackStore
        var decks: DeckStore
        var deck: Deck
    }

    private func makeRig(drawn: Bool = true, clock: @escaping () -> Date) throws -> Rig {
        let deck = Deck(name: "Spanish", color: .green, cards: (1...10).map { Card(front: "f\($0)", back: "b\($0)") })
        try DeckStorage(directory: root).save([deck])
        let deckStore = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let studyStore = StudyStore(storage: StudyStorage(directory: root))
        let sessions = SessionStore(storage: SessionStorage(directory: root), studyStorage: StudyStorage(directory: root))
        let screen = drawn
            ? ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876),
                            safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, displayID: 1, isBuiltIn: true)
            : ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1710, height: 1107), visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073.5),
                            safeAreaTop: 33.5, auxiliaryTopLeft: CGRect(x: 0, y: 1073.5, width: 762.5, height: 33.5),
                            auxiliaryTopRight: CGRect(x: 947.5, y: 1073.5, width: 762.5, height: 33.5), displayID: 1, isBuiltIn: true)
        let controller = NotchController(
            placementProvider: { NotchGeometry.placement(for: screen) },
            showsPanel: false, installsMonitors: false, watchDirectory: root,
            clock: clock,
            deckStore: { deckStore }, playbackStore: { playback }, settingsStore: { settings },
            studyStore: { studyStore }, sessionStore: { sessions }
        )
        addTeardownBlock { controller.stop() }
        controller.start()
        return Rig(controller: controller, sessions: sessions, settings: settings, playback: playback, decks: deckStore, deck: deck)
    }

    func testStartingASessionTakesOverTheDrawnPillWhateverTheStyle() throws {
        var t = now
        let rig = try makeRig { t }
        rig.settings.pillStyle = .classic
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.restStyle, .classic)
        let classicWidth = try XCTUnwrap(rig.controller.collapsedFrame).width

        rig.controller.model.onStartSession(10)
        guard case .running(let info) = rig.controller.model.session else { return XCTFail("running") }
        XCTAssertEqual(info.minutes, 10)
        XCTAssertEqual(rig.controller.model.restStyle, .session)
        XCTAssertEqual(try XCTUnwrap(rig.controller.collapsedFrame).width, NotchGeometry.sessionRestWidth)
        XCTAssertNotEqual(classicWidth, NotchGeometry.sessionRestWidth)

        rig.controller.model.onEndSession()
        t = now.addingTimeInterval(1)
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.restStyle, .session, "the recap keeps the pill for a few seconds")
        t = now.addingTimeInterval(60)
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.restStyle, .classic, "then the chosen style is back")
    }

    func testARealNotchKeepsItsClassicRestLayoutDuringASession() throws {
        let rig = try makeRig(drawn: false) { self.now }
        rig.controller.model.onStartSession(5)
        XCTAssertEqual(rig.controller.model.session != .idle, true)
        XCTAssertEqual(rig.controller.model.restStyle, .card, "Card, the default, stays beside the camera")
        rig.settings.pillStyle = .classic
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.restStyle, .classic)
    }

    func testCardsRotateEveryThirtySecondsInTheSessionAndBackToFiveMinutesAfter() throws {
        var t = now
        let rig = try makeRig { t }
        let first = try XCTUnwrap(rig.controller.model.showing).position
        rig.controller.model.onStartSession(5)
        XCTAssertEqual(rig.controller.model.showing?.position, first, "it starts on the card that was showing")
        XCTAssertEqual(rig.controller.model.rotationInterval, 30)
        XCTAssertEqual(rig.controller.model.nextRotation, now.addingTimeInterval(30))

        t = now.addingTimeInterval(31)
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.showing?.position, first % 10 + 1)
        XCTAssertEqual(rig.controller.model.nextRotation, now.addingTimeInterval(60))

        rig.controller.model.onEndSession()
        XCTAssertEqual(rig.controller.model.rotationInterval, CardScheduler.defaultInterval)
        XCTAssertEqual(rig.controller.model.nextRotation, CardScheduler().nextRotation(after: t))
    }

    func testFlippingInASessionCountsReviewedAndLeavesTheNormalRotationAlone() throws {
        var t = now
        let rig = try makeRig { t }
        rig.controller.model.onStartSession(5)
        t = now.addingTimeInterval(2)
        rig.controller.model.onFlip()
        guard case .running(let info) = rig.controller.model.session else { return XCTFail("running") }
        XCTAssertEqual(info.reviewed, 1)
        XCTAssertEqual(rig.controller.model.showing?.isFlipped, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PlaybackStorage(directory: root).fileURL.path), "the widget's rotation was not touched")
        XCTAssertEqual(rig.controller.model.study?.count, 1, "but it counts toward today's goal")
    }

    func testTheSessionEndsByItselfAndShowsTheRecapOnWake() throws {
        var t = now
        let rig = try makeRig { t }
        rig.controller.model.onStartSession(5)
        rig.controller.model.onFlip()
        t = now.addingTimeInterval(3 * 3600) // the Mac slept through the end
        rig.controller.refreshContent()
        guard case .recap(let result) = rig.controller.model.session else { return XCTFail("recap") }
        XCTAssertEqual(result.reviewed, 1)
        XCTAssertEqual(rig.controller.model.lastSession?.reviewed, 1)
        XCTAssertEqual(rig.controller.model.rotationInterval, CardScheduler.defaultInterval, "normal rotation again")
    }

    func testTwoDisplaysShareOneSession() throws {
        var t = now
        let rig = try makeRig { t }
        let second = NotchController(
            placementProvider: { nil }, showsPanel: false, installsMonitors: false, watchDirectory: root,
            clock: { t },
            deckStore: { DeckStore(storage: DeckStorage(directory: self.root), debounce: .milliseconds(5), onSaved: {}) },
            playbackStore: { rig.playback }, settingsStore: { rig.settings },
            studyStore: { StudyStore(storage: StudyStorage(directory: self.root)) }, sessionStore: { rig.sessions }
        )
        addTeardownBlock { second.stop() }
        second.start()
        rig.controller.model.onStartSession(5)
        t = now.addingTimeInterval(1)
        second.refreshContent()
        XCTAssertEqual(second.model.session, rig.controller.model.session, "one session, not one per screen")
    }

    func testTheSessionStyleShowsTheLastResultAtRest() throws {
        var t = now
        let rig = try makeRig { t }
        rig.settings.pillStyle = .session
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.restStyle, .session)
        XCTAssertNil(rig.controller.model.lastSession)
        rig.controller.model.onStartSession(5)
        rig.controller.model.onFlip()
        rig.controller.model.onEndSession()
        t = now.addingTimeInterval(120)
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.session, .idle)
        XCTAssertEqual(rig.controller.model.lastSession?.lastText, "Last: 1 card")
        XCTAssertEqual(rig.controller.model.restStyle, .session, "chosen as the style, so it stays")
    }

    func testDeletingTheDeckEndsTheSession() throws {
        var t = now
        let rig = try makeRig { t }
        rig.controller.model.onStartSession(5)
        XCTAssertNotNil(rig.sessions.active)
        _ = rig.decks.deleteDeck(rig.deck.id)
        t = now.addingTimeInterval(1)
        rig.controller.refreshContent()
        XCTAssertNil(rig.sessions.active, "a session can't go on without its deck")
        XCTAssertNil(rig.controller.model.showing)
        XCTAssertEqual(rig.controller.model.rotationInterval, CardScheduler.defaultInterval)
    }

    func testTheLengthButtonRemembersTheChoice() throws {
        let rig = try makeRig { self.now }
        XCTAssertEqual(rig.controller.model.sessionMinutes, 15)
        rig.controller.model.onSetSessionMinutes(25)
        XCTAssertEqual(rig.controller.model.sessionMinutes, 25)
        rig.controller.model.onStartSession(rig.controller.model.sessionMinutes)
        guard case .running(let info) = rig.controller.model.session else { return XCTFail("running") }
        XCTAssertEqual(info.minutes, 25)
    }

    func testWithoutASessionStoreTheControlsAreHidden() throws {
        let deckStore = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let controller = NotchController(
            placementProvider: { nil }, showsPanel: false, installsMonitors: false, watchDirectory: root,
            deckStore: { deckStore },
            playbackStore: { PlaybackStore(storage: PlaybackStorage(directory: self.root), onSaved: {}) },
            settingsStore: { SettingsStore(storage: SettingsStorage(directory: self.root), onSaved: {}) }
        )
        addTeardownBlock { controller.stop() }
        controller.start()
        XCTAssertFalse(controller.model.sessionsAvailable)
        controller.model.onStartSession(5)
        XCTAssertEqual(controller.model.session, .idle)
    }

    func testThePillWidthIsModest() {
        XCTAssertLessThanOrEqual(NotchGeometry.drawnWidth(forPositionText: "12/40", style: .session), 300)
    }
}

import SwiftUI
import XCTest

/// One study clock at a time (FLAS-61): the notch session and a Review sprint share it.
@MainActor
final class StudyClockGateTests: XCTestCase {
    private var root: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let deck = Deck(name: "Spanish", cards: (1...30).map { Card(front: "f\($0)", back: "b\($0)") })

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeSessions() -> SessionStore {
        SessionStore(storage: SessionStorage(directory: root), studyStorage: StudyStorage(directory: root))
    }

    /// A 15 minute session, 140 seconds in, with eight cards turned over: "12:40 left, 8 reviewed".
    private func runningSession(_ sessions: SessionStore) -> Date {
        sessions.start(deckID: deck.id, currentIndex: 0, minutes: 15, at: t0)
        for i in 0..<8 { sessions.flip(in: deck, at: t0.addingTimeInterval(Double(i) * 30 + 5)) }
        return t0.addingTimeInterval(140)
    }

    private func sprintInfo(reviewed: Int = 17, remaining: TimeInterval = 462, at now: Date) -> StudyClockInfo {
        StudyClockInfo(kind: .sprint, startedAt: now.addingTimeInterval(-138), endsAt: now.addingTimeInterval(remaining), minutes: 10, reviewed: reviewed)
    }

    // MARK: Transitions

    func testWithNothingRunningEveryoneMayStart() {
        let gate = StudyClockGate(sessions: makeSessions())
        XCTAssertEqual(gate.phase(at: t0), .idle)
        XCTAssertEqual(gate.requestSprintStart(at: t0), .allowed)
        XCTAssertTrue(gate.canStartSession)
        XCTAssertFalse(gate.isSprintRunning)
    }

    func testStartingASprintDuringASessionAsksFirstAndSaysWhatItWouldEnd() throws {
        let sessions = makeSessions()
        let now = runningSession(sessions)
        let gate = StudyClockGate(sessions: sessions)

        guard case .needsConfirmation(let info) = gate.requestSprintStart(at: now) else { return XCTFail("should ask") }
        XCTAssertEqual(info.kind, .session)
        XCTAssertEqual(info.reviewed, 8)
        XCTAssertEqual(info.remaining(at: now), 760, accuracy: 0.001)
        XCTAssertEqual(
            StudyClockGate.confirmationText(for: info, at: now),
            "12:40 left, 8 cards reviewed. Starting a sprint ends it and keeps its 8 cards."
        )
        XCTAssertNotNil(sessions.active, "asking changes nothing")
        XCTAssertFalse(gate.canStartSession)
    }

    func testTheConfirmationSaysCardInTheSingular() {
        let info = StudyClockInfo(kind: .session, startedAt: t0, endsAt: t0.addingTimeInterval(300), minutes: 5, reviewed: 1)
        XCTAssertEqual(
            StudyClockGate.confirmationText(for: info, at: t0.addingTimeInterval(60)),
            "4:00 left, 1 card reviewed. Starting a sprint ends it and keeps its 1 card."
        )
    }

    func testEndingTheSessionForASprintKeepsItsCardsAndLeavesItsRecap() throws {
        let sessions = makeSessions()
        let now = runningSession(sessions)
        let gate = StudyClockGate(sessions: sessions)

        gate.endSessionForSprint(at: now)
        XCTAssertNil(sessions.active)
        XCTAssertEqual(sessions.session.last?.reviewed, 8, "its eight cards are kept")
        XCTAssertEqual(gate.requestSprintStart(at: now), .allowed)

        gate.sprintStarted(sprintInfo(at: now), at: now)
        XCTAssertEqual(gate.phase(at: now), .running(sprintInfo(at: now)))
        XCTAssertTrue(gate.isSprintRunning)
    }

    func testASessionCannotStartWhileASprintRuns() {
        let gate = StudyClockGate(sessions: makeSessions())
        gate.sprintStarted(sprintInfo(at: t0), at: t0)
        XCTAssertFalse(gate.canStartSession)
        gate.sprintEnded(nil)
        XCTAssertTrue(gate.canStartSession)
    }

    func testTwoClocksNeverOverlapEvenIfASprintStartsOverASession() {
        let sessions = makeSessions()
        let now = runningSession(sessions)
        let gate = StudyClockGate(sessions: sessions)
        gate.sprintStarted(sprintInfo(at: now), at: now)
        XCTAssertNil(sessions.active, "the session was ended rather than left running beside it")
        XCTAssertEqual(sessions.session.last?.reviewed, 8)
        if case .running(let info) = gate.phase(at: now) { XCTAssertEqual(info.kind, .sprint) } else { XCTFail("running") }
    }

    func testASprintsResultIsTheRecapAndTheLastResult() {
        let sessions = makeSessions()
        let gate = StudyClockGate(sessions: sessions)
        gate.sprintStarted(sprintInfo(at: t0), at: t0)
        let result = StudySession.Result(reviewed: 23, minutes: 10, endedAt: t0.addingTimeInterval(600))
        gate.sprintEnded(result)

        XCTAssertNil(gate.sprint)
        XCTAssertEqual(gate.phase(at: result.endedAt.addingTimeInterval(3)), .recap(result))
        XCTAssertEqual(
            gate.phase(at: result.endedAt.addingTimeInterval(StudySession.recapDuration + 1)), .idle,
            "the same eight seconds as a session's"
        )
        XCTAssertEqual(sessions.session.last?.lastText, "Last: 23 cards")
        XCTAssertEqual(result.text, "23 cards in 10 min")
    }

    func testBothKindsLeaveTheSameRecapAndLast() {
        // A session that ends...
        let sessions = makeSessions()
        sessions.start(deckID: deck.id, currentIndex: 0, minutes: 5, at: t0)
        sessions.flip(in: deck, at: t0.addingTimeInterval(5))
        sessions.end(at: t0.addingTimeInterval(120))
        let fromSession = sessions.session

        // ...and a sprint that ends with the same figures.
        let other = makeSessions2()
        let gate = StudyClockGate(sessions: other)
        gate.sprintStarted(sprintInfo(at: t0), at: t0)
        gate.sprintEnded(StudySession.Result(reviewed: 1, minutes: 2, endedAt: t0.addingTimeInterval(120)))
        let fromSprint = other.session

        XCTAssertEqual(fromSession.last, fromSprint.last)
        XCTAssertEqual(fromSession.recapUntil, fromSprint.recapUntil)
        XCTAssertEqual(fromSession.recap(at: t0.addingTimeInterval(125))?.text, fromSprint.recap(at: t0.addingTimeInterval(125))?.text)
    }

    func testASprintWithNothingGradedLeavesLastAsItWas() {
        let sessions = makeSessions()
        sessions.start(deckID: deck.id, currentIndex: 0, minutes: 5, at: t0)
        sessions.flip(in: deck, at: t0.addingTimeInterval(5))
        sessions.end(at: t0.addingTimeInterval(60))
        let before = sessions.session.last
        let gate = StudyClockGate(sessions: sessions)
        gate.sprintStarted(sprintInfo(reviewed: 0, at: t0), at: t0)
        gate.sprintEnded(nil)
        XCTAssertEqual(sessions.session.last, before)
    }

    func testTheSprintsCountAndClockFollowTheSprint() {
        let gate = StudyClockGate(sessions: makeSessions())
        gate.sprintChanged(sprintInfo(at: t0))
        XCTAssertNil(gate.sprint, "nothing to change when no sprint is running")
        gate.sprintStarted(sprintInfo(reviewed: 0, at: t0), at: t0)
        gate.sprintChanged(sprintInfo(reviewed: 5, at: t0))
        XCTAssertEqual(gate.sprint?.reviewed, 5)
    }

    func testAfterARelaunchOnlyThePersistedSessionRuns() {
        let first = makeSessions()
        let now = runningSession(first)
        _ = StudyClockGate(sessions: first)
        // The app quits and starts again: a sprint doesn't survive a quit, a session does.
        let relaunched = StudyClockGate(sessions: makeSessions())
        XCTAssertNil(relaunched.sprint)
        guard case .running(let info) = relaunched.phase(at: now) else { return XCTFail("the session carries on") }
        XCTAssertEqual(info.kind, .session)
        XCTAssertFalse(relaunched.canStartSession)
        XCTAssertTrue(relaunched.requestSprintStart(at: now) != .allowed)
    }

    func testTheGatePublishesWhenTheSessionStoreChanges() {
        let sessions = makeSessions()
        let gate = StudyClockGate(sessions: sessions)
        var changes = 0
        let token = gate.objectWillChange.sink { changes += 1 }
        sessions.start(deckID: deck.id, currentIndex: 0, minutes: 5, at: t0)
        gate.sprintStarted(sprintInfo(at: t0), at: t0)
        XCTAssertGreaterThanOrEqual(changes, 2)
        token.cancel()
    }

    private func makeSessions2() -> SessionStore {
        let other = root.appendingPathComponent("other", isDirectory: true)
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        return SessionStore(storage: SessionStorage(directory: other), studyStorage: StudyStorage(directory: other))
    }

    // MARK: What the notch says

    func testThePillAndAccessibilityTextPerState() {
        let now = t0.addingTimeInterval(138)
        let sprint = StudyClockInfo(kind: .sprint, startedAt: t0, endsAt: t0.addingTimeInterval(600), minutes: 10, reviewed: 17)
        XCTAssertEqual(sprint.accessibilityLabel(at: t0.addingTimeInterval(600 - 462)), "Review sprint, 7:42 left, 17 cards reviewed")
        XCTAssertEqual(sprint.openText(at: t0.addingTimeInterval(600 - 462)), "Sprint · 7:42 left · 17 reviewed")

        let session = StudyClockInfo(kind: .session, startedAt: t0, endsAt: t0.addingTimeInterval(900), minutes: 15, reviewed: 8)
        XCTAssertEqual(session.accessibilityLabel(at: t0.addingTimeInterval(140)), "Study session, 12:40 left, 8 cards reviewed")
        XCTAssertEqual(session.openText(at: t0.addingTimeInterval(140)), "12:40 left · 8 reviewed")
        _ = now
    }

    func testAPausedSprintsClockStandsStill() {
        var info = StudyClockInfo(kind: .sprint, startedAt: t0, endsAt: t0.addingTimeInterval(600), minutes: 10, reviewed: 4)
        info.pausedAt = t0.addingTimeInterval(100)
        XCTAssertEqual(info.remaining(at: t0.addingTimeInterval(400)), 500, accuracy: 0.001)
        XCTAssertEqual(info.progress(at: t0.addingTimeInterval(400)), 100.0 / 600, accuracy: 0.0001)
        XCTAssertEqual(info.accessibilityLabel(at: t0.addingTimeInterval(400)), "Review sprint, 8:20 left, 4 cards reviewed")
    }

    func testGradingInTheNotchIsAllowedDuringASprintButNotASession() {
        let model = NotchModel()
        XCTAssertTrue(model.canGrade)
        model.session = .running(StudyClockInfo(kind: .session, startedAt: t0, endsAt: t0.addingTimeInterval(60), minutes: 1, reviewed: 0))
        XCTAssertFalse(model.canGrade, "a session has its own rotation")
        model.session = .running(sprintInfo(at: t0))
        XCTAssertTrue(model.canGrade, "a sprint leaves the notch's rotation alone")
        XCTAssertTrue(model.session.isSprint)
        XCTAssertFalse(model.session.isNotchSession)
    }
}

@MainActor
final class NotchBesideASprintTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private struct Rig {
        var controller: NotchController
        var sessions: SessionStore
        var gate: StudyClockGate
        var playback: PlaybackStore
        var deck: Deck
    }

    private var wentToSprint = 0

    private func makeRig(clock: @escaping () -> Date) throws -> Rig {
        let deck = Deck(name: "Spanish", color: .green, cards: (1...10).map { Card(front: "f\($0)", back: "b\($0)") })
        try DeckStorage(directory: root).save([deck])
        let deckStore = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let study = StudyStore(storage: StudyStorage(directory: root))
        let sessions = SessionStore(storage: SessionStorage(directory: root), studyStorage: StudyStorage(directory: root))
        let gate = StudyClockGate(sessions: sessions)
        let screen = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876),
            safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, displayID: 1, isBuiltIn: true
        )
        let controller = NotchController(
            placementProvider: { NotchGeometry.placement(for: screen) },
            showsPanel: false, installsMonitors: false, watchDirectory: root, clock: clock,
            deckStore: { deckStore }, playbackStore: { playback }, settingsStore: { settings },
            studyStore: { study }, sessionStore: { sessions }, studyClock: { gate },
            goToSprint: { [unowned self] in wentToSprint += 1 }
        )
        addTeardownBlock { controller.stop() }
        controller.start()
        return Rig(controller: controller, sessions: sessions, gate: gate, playback: playback, deck: deck)
    }

    private func sprint(reviewed: Int, endsIn: TimeInterval = 462) -> StudyClockInfo {
        StudyClockInfo(kind: .sprint, startedAt: now.addingTimeInterval(endsIn - 600), endsAt: now.addingTimeInterval(endsIn), minutes: 10, reviewed: reviewed)
    }

    func testTheNotchSessionBehavesAsBeforeWhenNoSprintRuns() throws {
        let rig = try makeRig { self.now }
        rig.controller.model.onStartSession(5)
        XCTAssertTrue(rig.controller.model.session.isNotchSession)
        XCTAssertEqual(rig.controller.model.rotationInterval, StudySession.rotationInterval, "30-second rotation")
        XCTAssertFalse(rig.controller.model.canGrade)
        rig.controller.model.onEndSession()
        XCTAssertEqual(rig.sessions.session.last?.reviewed, 0)
    }

    func testASprintShowsInTheNotchAsTheSameRunningPhase() throws {
        let rig = try makeRig { self.now }
        rig.gate.sprintStarted(sprint(reviewed: 17), at: now)
        rig.controller.refreshContent()

        guard case .running(let info) = rig.controller.model.session else { return XCTFail("running") }
        XCTAssertEqual(info.kind, .sprint)
        XCTAssertEqual(info.reviewed, 17)
        XCTAssertEqual(info.remaining(at: now), 462, accuracy: 0.001)
        XCTAssertEqual(rig.controller.model.restStyle, .session, "a drawn notch's pill carries the ring, time and count")
        XCTAssertEqual(info.accessibilityLabel(at: now), "Review sprint, 7:42 left, 17 cards reviewed")
    }

    func testTheNotchKeepsItsOwnRotationDuringASprint() throws {
        let rig = try makeRig { self.now }
        let before = rig.controller.model.showing
        rig.gate.sprintStarted(sprint(reviewed: 3), at: now)
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.rotationInterval, CardScheduler.defaultInterval, "not the session's 30 seconds")
        XCTAssertEqual(rig.controller.model.showing?.card.id, before?.card.id)
        XCTAssertTrue(rig.controller.model.canGrade)
        // And flipping still goes to the shared playback, as always.
        rig.controller.model.onFlip()
        XCTAssertNotNil(rig.playback.state(for: rig.deck.id).flip)
    }

    func testStartSessionGivesWayToGoToSprint() throws {
        let rig = try makeRig { self.now }
        rig.gate.sprintStarted(sprint(reviewed: 1), at: now)
        rig.controller.refreshContent()

        rig.controller.model.onStartSession(5) // even if something still calls it
        XCTAssertNil(rig.sessions.active, "one clock at a time")
        rig.controller.model.onGoToSprint()
        XCTAssertEqual(wentToSprint, 1)
    }

    func testTheSprintSurvivesTheNotchRefreshingAndTheMacWakingFromSleep() throws {
        var t = now
        let rig = try makeRig { t }
        rig.gate.sprintStarted(sprint(reviewed: 6), at: now)
        rig.controller.refreshContent()

        t = now.addingTimeInterval(20 * 60) // slept through the end of its time
        rig.controller.refreshContent()
        XCTAssertTrue(rig.gate.isSprintRunning, "the notch doesn't end a sprint; only the sprint does")
        guard case .running(let info) = rig.controller.model.session else { return XCTFail("still running") }
        XCTAssertEqual(info.remaining(at: t), 0)
        XCTAssertEqual(info.reviewed, 6)
    }

    func testFinishingASprintLeavesTheSameRecapAndLastAsASession() throws {
        var t = now
        let rig = try makeRig { t }
        rig.gate.sprintStarted(sprint(reviewed: 23), at: now)
        t = now.addingTimeInterval(600)
        rig.gate.sprintEnded(StudySession.Result(reviewed: 23, minutes: 10, endedAt: t))
        rig.controller.refreshContent()

        guard case .recap(let result) = rig.controller.model.session else { return XCTFail("recap") }
        XCTAssertEqual(result.text, "23 cards in 10 min")
        XCTAssertEqual(rig.controller.model.lastSession?.lastText, "Last: 23 cards")

        t = now.addingTimeInterval(600 + StudySession.recapDuration + 1)
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.session, .idle)
        XCTAssertEqual(rig.controller.model.lastSession?.lastText, "Last: 23 cards")
    }

    func testTheSprintSharesTheDaysGoalWithTheNotch() throws {
        let rig = try makeRig { self.now }
        // A sprint grades the card the notch happens to be showing...
        let shown = try XCTUnwrap(rig.controller.model.showing?.card)
        try PlaybackActions.grade(.good, cardID: shown.id, in: rig.deck, storage: PlaybackStorage(directory: root), at: now)
        rig.playback.refresh()
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.study?.count, 1)

        // ...and turning that same card over in the notch the same day doesn't count it again.
        XCTAssertEqual(rig.controller.model.showing?.card.id, shown.id)
        rig.controller.model.onFlip()
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.study?.count, 1, "once a day per card, whichever surface")
        XCTAssertEqual(StudyStorage(directory: root).load().count(on: now), 1)
    }

    func testTheOpenNotchShowsGoToSprintInPlaceOfStartSession() throws {
        let model = NotchModel()
        model.sessionsAvailable = true
        model.session = .running(sprint(reviewed: 17))
        let view = SessionControls(model: model).environment(\.accentChoice, .default)
        let renderer = ImageRenderer(content: view.frame(width: 360, height: 40).background(Color.black))
        XCTAssertNotNil(renderer.cgImage)
        XCTAssertTrue(model.session.isSprint)
        XCTAssertEqual(sprint(reviewed: 17).openText(at: now), "Sprint · 7:42 left · 17 reviewed")
    }
}

@MainActor
final class SprintReportsToTheClockTests: XCTestCase {
    private var root: URL!
    private var decks: [Deck] = []
    private var clockNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        decks = [Deck(name: "a", cards: (1...6).map { Card(front: "a\($0)", back: "back") })]
        clockNow = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A sprint wired to the gate the way the main window wires it.
    private func startSprint(gate: StudyClockGate, history: RunHistoryStore) -> ReviewSprintModel {
        var setup = ReviewSetup(minutes: 10)
        setup.ticked = Set(decks.map(\.id))
        let model = ReviewSprintModel.start(
            setup: setup, decks: { [unowned self] in decks }, playback: { [:] },
            grader: { _, _, _, _ in }, clock: { [unowned self] in clockNow },
            onFinished: { [gate] record in
                if let record { history.record(record) }
                gate.sprintEnded(record.map { StudySession.Result(reviewed: $0.reviewed, minutes: $0.minutes, endedAt: Date()) })
            },
            onClock: { [gate] in gate.sprintChanged($0) }
        )
        gate.sprintStarted(model.clockInfo, at: clockNow)
        return model
    }

    func testTheNotchSeesTheSprintsCountAndPause() {
        let sessions = SessionStore(storage: SessionStorage(directory: root), studyStorage: StudyStorage(directory: root))
        let gate = StudyClockGate(sessions: sessions)
        let model = startSprint(gate: gate, history: RunHistoryStore(storage: RunHistoryStorage(directory: root)))
        XCTAssertEqual(gate.sprint?.reviewed, 0)
        XCTAssertEqual(gate.sprint?.remaining(at: clockNow), 600)

        clockNow = clockNow.addingTimeInterval(30)
        model.handle(.space); model.handle(.grade(.good))
        XCTAssertEqual(gate.sprint?.reviewed, 1)
        XCTAssertEqual(gate.sprint?.remaining(at: clockNow), 570)

        model.handle(.pause)
        XCTAssertNotNil(gate.sprint?.pausedAt)
        XCTAssertEqual(gate.sprint?.remaining(at: clockNow.addingTimeInterval(300)), 570, "stands still while paused")
        model.handle(.pause)
        XCTAssertNil(gate.sprint?.pausedAt)
    }

    func testQuittingEndsTheSprintAndSavesIt() {
        let sessions = SessionStore(storage: SessionStorage(directory: root), studyStorage: StudyStorage(directory: root))
        let gate = StudyClockGate(sessions: sessions)
        let history = RunHistoryStore(storage: RunHistoryStorage(directory: root))
        let model = startSprint(gate: gate, history: history)
        clockNow = clockNow.addingTimeInterval(30)
        model.handle(.space); model.handle(.grade(.good))
        clockNow = clockNow.addingTimeInterval(60)
        model.handle(.space); model.handle(.grade(.easy))

        model.endForQuit()

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(history.history.last?.reviewed, 2, "saved")
        XCTAssertEqual(RunHistoryStorage(directory: root).load().last?.reviewed, 2, "and on disk before the app is gone")
        XCTAssertNil(gate.sprint)
        XCTAssertEqual(sessions.session.last?.reviewed, 2, "it shows as Last: 2 cards")
    }

    func testFinishingTheQueueClearsTheGateToo() {
        let sessions = SessionStore(storage: SessionStorage(directory: root), studyStorage: StudyStorage(directory: root))
        let gate = StudyClockGate(sessions: sessions)
        let model = startSprint(gate: gate, history: RunHistoryStore(storage: RunHistoryStorage(directory: root)))
        for _ in 0..<6 {
            clockNow = clockNow.addingTimeInterval(10)
            model.handle(.space); model.handle(.grade(.good))
        }
        XCTAssertEqual(model.phase, .finished(.queueFinished))
        XCTAssertNil(gate.sprint)
        XCTAssertEqual(sessions.session.last?.reviewed, 6)
        XCTAssertTrue(gate.canStartSession)
    }
}

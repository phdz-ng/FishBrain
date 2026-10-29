import XCTest

/// The swimming-fish pill (FLAS-38): where the fish is, and how often anything redraws.
final class FishSwimTests: XCTestCase {
    private let interval = CardScheduler.defaultInterval // 5 minutes
    private let next = Date(timeIntervalSince1970: 3000)

    private func progress(secondsLeft: Double, reduceMotion: Bool = false) -> Double {
        FishSwim.progress(until: next, now: next.addingTimeInterval(-secondsLeft), reduceMotion: reduceMotion)
    }

    func testTheFishStartsAtTheLeftWhenACardArrivesAndEndsAtTheRight() {
        XCTAssertEqual(progress(secondsLeft: 300), 0, accuracy: 0.0001)
        XCTAssertEqual(progress(secondsLeft: 150), 0.5, accuracy: 0.0001)
        XCTAssertEqual(progress(secondsLeft: 0), 1, accuracy: 0.0001)
    }

    func testItIsWorkedOutFromTheClockSoSleepAndWakeCannotMakeItWrong() {
        // The Mac slept through the whole slot: the fish is at the end, not past it.
        XCTAssertEqual(progress(secondsLeft: -40), 1)
        // Woke up long before the slot began (clock change): at the start, not before it.
        XCTAssertEqual(progress(secondsLeft: 900), 0)
    }

    func testReduceMotionMovesTheFishInWholeStepsOfFifteenSeconds() {
        XCTAssertEqual(progress(secondsLeft: 300, reduceMotion: true), 0)
        XCTAssertEqual(progress(secondsLeft: 286, reduceMotion: true), 0, "14 s in: still on the first step")
        XCTAssertEqual(progress(secondsLeft: 285, reduceMotion: true), 15 / interval, accuracy: 0.0001)
        XCTAssertEqual(progress(secondsLeft: 271, reduceMotion: true), 15 / interval, accuracy: 0.0001)
        XCTAssertEqual(progress(secondsLeft: 0, reduceMotion: true), 1, accuracy: 0.0001)
    }

    func testReduceMotionNeverRunsAheadOfTheRealPosition() {
        for left in stride(from: 300.0, through: 0, by: -7) {
            XCTAssertLessThanOrEqual(progress(secondsLeft: left, reduceMotion: true), progress(secondsLeft: left) + 0.0001)
        }
    }

    func testTheRedrawIsSlowNeverPerFrameAndSlowerStillWithReduceMotion() {
        XCTAssertEqual(FishSwim.updatePeriod(reduceMotion: false), 5)
        XCTAssertEqual(FishSwim.updatePeriod(reduceMotion: true), 15)
        XCTAssertGreaterThanOrEqual(FishSwim.updatePeriod(reduceMotion: false), 1, "at most once a second")
    }

    func testTheFishStaysInsideTheTrack() {
        XCTAssertEqual(FishSwim.offset(progress: 0, trackWidth: 92, fishWidth: 20), 0)
        XCTAssertEqual(FishSwim.offset(progress: 1, trackWidth: 92, fishWidth: 20), 72, "its right edge is the track's end")
        XCTAssertEqual(FishSwim.offset(progress: 0.5, trackWidth: 92, fishWidth: 20), 36)
        XCTAssertEqual(FishSwim.offset(progress: 3, trackWidth: 92, fishWidth: 20), 72, "clamped")
        XCTAssertEqual(FishSwim.offset(progress: -1, trackWidth: 92, fishWidth: 20), 0)
        XCTAssertEqual(FishSwim.offset(progress: 1, trackWidth: 10, fishWidth: 20), 0, "a track shorter than the fish")
    }

    func testTheTailFlicksOneWayThenTheOther() {
        let first = Date(timeIntervalSince1970: 1000)
        XCTAssertNotEqual(FishSwim.tailLeansUp(at: first), FishSwim.tailLeansUp(at: first.addingTimeInterval(FishSwim.tick)))
        XCTAssertEqual(FishSwim.tailLeansUp(at: first), FishSwim.tailLeansUp(at: first.addingTimeInterval(FishSwim.tick * 2)))
        XCTAssertEqual(FishSwim.tailLeansUp(at: first), FishSwim.tailLeansUp(at: first.addingTimeInterval(1)), "steady within a tick")
    }

    func testTheFishPillIsWiderThanClassicButStillModest() {
        let classic = NotchGeometry.drawnWidth(forPositionText: "12/40", style: .classic)
        let fish = NotchGeometry.drawnWidth(forPositionText: "12/40", style: .fish)
        XCTAssertGreaterThan(fish, classic)
        XCTAssertLessThanOrEqual(NotchGeometry.drawnWidth(forPositionText: "1234/5678", style: .fish), 300)
        XCTAssertEqual(NotchGeometry.drawnWidth(forPositionText: "12/40"), classic, "classic is the default")
    }

    func testTheTrackFitsInsideTheFishPill() {
        // icon 16 + gaps and padding + track + a position label of about 30.
        let needed = 12 + 16 + 9 + FishPillContent.trackWidth + 9 + 30 + 12
        XCTAssertLessThanOrEqual(needed, NotchGeometry.fishRestWidth + 4)
    }

    func testFishIsOnOfferInTheStylePicker() {
        XCTAssertTrue(PillStyle.available.contains(.fish))
        XCTAssertEqual(PillStyle.resolved(.fish), .fish)
        XCTAssertEqual(Set(PillStyle.available), Set(PillStyle.allCases), "all four styles are built")
    }
}

@MainActor
final class FishPillNotchTests: XCTestCase {
    func testTheDrawnNotchWidensForTheFishAndAnOpenNotchStopsRedrawing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try DeckStorage(directory: root).save([Deck(name: "Spanish", color: .green, cards: (1...40).map { Card(front: "f\($0)", back: "b\($0)") })])
        let deckStore = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let plain = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876),
            safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, displayID: 1, isBuiltIn: true
        )
        let controller = NotchController(
            placementProvider: { NotchGeometry.placement(for: plain) },
            showsPanel: false, installsMonitors: false, watchDirectory: root,
            deckStore: { deckStore }, playbackStore: { playback }, settingsStore: { settings }
        )
        addTeardownBlock { controller.stop() }
        settings.pillStyle = .classic
        controller.start()
        let classicWidth = try XCTUnwrap(controller.collapsedFrame).width

        settings.pillStyle = .fish
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.model.pillStyle, .fish)
        XCTAssertGreaterThan(try XCTUnwrap(controller.collapsedFrame).width, classicWidth, "room for the fish to swim")
        XCTAssertEqual(controller.model.collapsedSize.width, try XCTUnwrap(controller.collapsedFrame).width, "the panel was resized to match")

        settings.pillStyle = .classic
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try XCTUnwrap(controller.collapsedFrame).width, classicWidth, "and back")
    }
}

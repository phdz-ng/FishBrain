import AppKit
import SwiftUI
import XCTest

final class NotchCardRuleTests: XCTestCase {
    // MARK: Below the camera

    func testContentStartsBelowTheCameraHousing() {
        XCTAssertGreaterThan(NotchCard.contentTopInset(notchHeight: 33.5), 33.5)
        XCTAssertGreaterThan(NotchCard.contentTopInset(notchHeight: 24), 24, "and below the menu bar on a Mac without a notch")
        XCTAssertEqual(NotchCard.contentTopInset(notchHeight: 33.5), 43.5)
    }

    func testTheCardFitsInTheOpenPanelBelowTheCamera() {
        // 222 pt tall panel: the content area under the camera still leaves room for header, card and countdown.
        let room = NotchGeometry.expandedSize.height - NotchCard.contentTopInset(notchHeight: 33.5) - 16
        XCTAssertGreaterThan(room, 120)
    }

    // MARK: Flip

    func testTheBackShowsPastTheQuarterTurn() {
        XCTAssertFalse(NotchCard.isShowingBack(angle: 0))
        XCTAssertFalse(NotchCard.isShowingBack(angle: 89.9))
        XCTAssertTrue(NotchCard.isShowingBack(angle: 90))
        XCTAssertTrue(NotchCard.isShowingBack(angle: 180))
        XCTAssertTrue(NotchCard.isShowingBack(angle: 269.9))
        XCTAssertFalse(NotchCard.isShowingBack(angle: 270))
        XCTAssertFalse(NotchCard.isShowingBack(angle: 360))
        XCTAssertTrue(NotchCard.isShowingBack(angle: -180))
    }

    func testFlippedMeansTurnedAroundHalfway() {
        XCTAssertEqual(NotchCard.flipAngle(isFlipped: false), 0)
        XCTAssertEqual(NotchCard.flipAngle(isFlipped: true), 180)
    }

    func testTheFaceChangesExactlyOnceDuringAFlip() {
        let angles = stride(from: 0.0, through: 180.0, by: 1.0)
        let faces = angles.map(NotchCard.isShowingBack)
        let changes = zip(faces, faces.dropFirst()).filter { $0 != $1 }.count
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(faces.first, false)
        XCTAssertEqual(faces.last, true)
    }

    // MARK: Countdown

    func testCountdownAndProgress() {
        let next = Date(timeIntervalSince1970: 300)
        XCTAssertEqual(NotchCard.secondsRemaining(until: next, now: Date(timeIntervalSince1970: 186)), 114)
        XCTAssertEqual(NowShowing.format(seconds: 114), "1:54")
        XCTAssertEqual(NotchCard.progress(until: next, now: Date(timeIntervalSince1970: 186)), 0.62, accuracy: 0.0001)
    }

    func testTheCountdownNeverShowsZeroOrGoesNegative() {
        let next = Date(timeIntervalSince1970: 300)
        XCTAssertEqual(NotchCard.secondsRemaining(until: next, now: Date(timeIntervalSince1970: 299.6)), 1)
        XCTAssertEqual(NotchCard.secondsRemaining(until: next, now: Date(timeIntervalSince1970: 305)), 1, "past the boundary until the card changes")
        XCTAssertEqual(NotchCard.progress(until: next, now: Date(timeIntervalSince1970: 400)), 1)
        XCTAssertEqual(NotchCard.progress(until: next, now: Date(timeIntervalSince1970: -50)), 0)
    }

    func testAFreshSlotStartsAtFiveMinutes() {
        let next = Date(timeIntervalSince1970: 600)
        XCTAssertEqual(NowShowing.format(seconds: NotchCard.secondsRemaining(until: next, now: Date(timeIntervalSince1970: 300))), "5:00")
        XCTAssertEqual(NotchCard.progress(until: next, now: Date(timeIntervalSince1970: 300)), 0, accuracy: 0.0001)
    }
}

@MainActor
final class NotchCardControllerTests: XCTestCase {
    private var root: URL!
    private let notched = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073.5),
        safeAreaTop: 33.5,
        auxiliaryTopLeft: CGRect(x: 0, y: 1073.5, width: 762.5, height: 33.5),
        auxiliaryTopRight: CGRect(x: 947.5, y: 1073.5, width: 762.5, height: 33.5)
    )

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController(
        cards: Int = 10,
        collapseAnimation: Duration = .milliseconds(10),
        showsPanel: Bool = false,
        display: ScreenMetrics? = nil,
        now: Date = Date(timeIntervalSince1970: 100)
    ) throws -> (NotchController, DeckStore, PlaybackStore) {
        let deck = Deck(name: "Everyday Spanish", color: .green, cards: (1...cards).map { Card(front: "front \($0)", back: "back \($0)") })
        try DeckStorage(directory: root).save([deck])
        let decks = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let screen = display ?? notched
        let controller = NotchController(
            placementProvider: { NotchGeometry.placement(for: screen) },
            showsPanel: showsPanel,
            installsMonitors: false,
            expandDelay: .milliseconds(5),
            collapseDelay: .milliseconds(5),
            collapseAnimation: collapseAnimation,
            watchDirectory: root,
            clock: { now },
            deckStore: { decks },
            playbackStore: { playback },
            settingsStore: { settings }
        )
        addTeardownBlock { controller.stop() }
        return (controller, decks, playback)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Flip and skip

    func testClickingTheCardFlipsItAndAgainFlipsItBack() throws {
        let (controller, _, _) = try makeController()
        controller.start()
        XCTAssertEqual(controller.model.showing?.isFlipped, false)

        controller.model.onFlip()
        XCTAssertEqual(controller.model.showing?.isFlipped, true)

        controller.model.onFlip()
        XCTAssertEqual(controller.model.showing?.isFlipped, false)
    }

    func testSkipMovesToTheNextCardAtOnceFrontSideUp() throws {
        let (controller, _, _) = try makeController()
        controller.start()
        controller.model.onFlip()
        XCTAssertEqual(controller.model.showing?.positionText, "1/10")
        XCTAssertEqual(controller.model.showing?.isFlipped, true)

        controller.model.onSkip()
        XCTAssertEqual(controller.model.showing?.positionText, "2/10")
        XCTAssertEqual(controller.model.showing?.isFlipped, false)
    }

    func testFlipsAndSkipsReachTheWidgetsThroughTheSharedPlaybackFile() throws {
        let (controller, decks, _) = try makeController()
        controller.start()
        controller.model.onSkip()
        controller.model.onFlip()

        // A widget building its entry at the same moment reads the same shared file.
        let entry = FishBrainEntry.make(
            decks: decks.decks, playback: PlaybackStorage(directory: root).load(), accent: .indigo, at: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(entry.showing?.deckName, "Everyday Spanish")
        XCTAssertEqual(entry.showing?.isFlipped, true, "the widget shows the flip made in the notch")
        XCTAssertEqual(entry.showing?.position, controller.model.showing?.position, "and the same card")
    }

    func testAFlipMadeInAWidgetAppearsInTheNotch() throws {
        let (controller, decks, _) = try makeController()
        controller.start()
        XCTAssertEqual(controller.model.showing?.isFlipped, false)

        // The widget's button flips through its own storage instances in the same folder.
        try PlaybackActions.perform(.flip, deckID: decks.decks[0].id.uuidString, decks: DeckStorage(directory: root), playback: PlaybackStorage(directory: root), at: Date(timeIntervalSince1970: 100))

        let deadline = Date().addingTimeInterval(4)
        while controller.model.showing?.isFlipped != true && Date() < deadline { spin(0.05) }
        XCTAssertEqual(controller.model.showing?.isFlipped, true, "noticed through the folder watcher, with no polling")
    }

    func testNothingHappensWithNoDeck() throws {
        let decks = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let controller = NotchController(
            placementProvider: { NotchGeometry.placement(for: self.notched) }, showsPanel: false, installsMonitors: false,
            watchDirectory: root, deckStore: { decks }, playbackStore: { playback }, settingsStore: { settings }
        )
        addTeardownBlock { controller.stop() }
        controller.start()
        controller.model.onFlip()
        controller.model.onSkip()
        XCTAssertTrue(playback.states.isEmpty)
    }

    // MARK: Countdown only while open

    func testTheCountdownExistsOnlyWhileTheNotchIsOpen() async throws {
        let (controller, _, _) = try makeController(collapseAnimation: .milliseconds(40))
        controller.start()
        XCTAssertFalse(controller.model.showsExpandedContent, "collapsed: nothing ticks")

        controller.expand()
        XCTAssertTrue(controller.model.showsExpandedContent)

        controller.collapse()
        XCTAssertTrue(controller.model.showsExpandedContent, "stays until the close animation has finished")
        await controller.pendingFinishCollapse?.value
        XCTAssertFalse(controller.model.showsExpandedContent, "closed: the once-a-second timer is gone")
    }

    func testReopeningDuringTheCloseKeepsTheCountdown() async throws {
        let (controller, _, _) = try makeController(collapseAnimation: .milliseconds(60))
        controller.start()
        controller.expand()
        controller.collapse()
        controller.expand()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(controller.model.showsExpandedContent)
    }

    func testTheModelKnowsWhenTheCardNextChanges() throws {
        let (controller, _, _) = try makeController()
        controller.start()
        controller.refreshContent(at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(controller.model.nextRotation, Date(timeIntervalSince1970: 300))
        controller.refreshContent(at: Date(timeIntervalSince1970: 400))
        XCTAssertEqual(controller.model.nextRotation, Date(timeIntervalSince1970: 600))
    }

    // MARK: Below the camera

    func testTheModelCarriesTheCameraHeightSoContentStartsBelowIt() throws {
        let (controller, _, _) = try makeController()
        controller.start()
        XCTAssertEqual(controller.model.notchHeight, 33.5)
        XCTAssertGreaterThan(NotchCard.contentTopInset(notchHeight: controller.model.notchHeight), controller.model.notchHeight)
    }

    // MARK: First click

    func testTheViewsAcceptTheClickThatAlsoActivates() throws {
        XCTAssertTrue(FirstMouseContainerView().acceptsFirstMouse(for: nil))
        XCTAssertTrue(FirstMouseHostingView(rootView: Text("x")).acceptsFirstMouse(for: nil))
    }

    /// A real mouse click delivered into the open panel, while this test process is not the active
    /// app, reaches the card's button on the first click.
    func testARealClickOnTheCardFlipsItWithoutTheAppBeingActive() throws {
        // Far off any real display so the panel can be shown without appearing on screen.
        let far = ScreenMetrics(
            frame: CGRect(x: -60_000, y: 0, width: 1710, height: 1107),
            visibleFrame: CGRect(x: -60_000, y: 0, width: 1710, height: 1073.5),
            safeAreaTop: 33.5,
            auxiliaryTopLeft: CGRect(x: -60_000, y: 1073.5, width: 762.5, height: 33.5),
            auxiliaryTopRight: CGRect(x: -60_000 + 947.5, y: 1073.5, width: 762.5, height: 33.5)
        )
        let (controller, _, playback) = try makeController(showsPanel: true, display: far)
        controller.start()
        controller.expand()
        spin(0.8) // let the spring settle and the view lay out
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertFalse(NSApp.isActive, "this test must run without FishBrain active")
        XCTAssertFalse(panel.isKeyWindow)

        let deck = try XCTUnwrap(controller.model.showing).deckID
        XCTAssertNil(playback.state(for: deck).flip)

        // The middle of the card: horizontally centered, in the lower-middle of the open panel
        // (window coordinates start at the bottom left).
        let point = CGPoint(x: panel.frame.width / 2, y: 80)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            panel.sendEvent(event)
            spin(0.1)
        }

        XCTAssertNotNil(playback.state(for: deck).flip, "the first click flipped the card")
        XCTAssertFalse(panel.isKeyWindow, "and it never took focus")
    }
}

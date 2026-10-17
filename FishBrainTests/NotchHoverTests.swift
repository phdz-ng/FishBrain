import AppKit
import SwiftUI
import XCTest

final class NotchHoverRuleTests: XCTestCase {
    private let collapsed = CGRect(x: 729, y: 1074, width: 253, height: 33)
    private let expanded = CGRect(x: 645, y: 885, width: 420, height: 222)

    func testThePointerOnTheRestingPanelOpensIt() {
        XCTAssertTrue(NotchHover.shouldExpand(pointer: CGPoint(x: 855, y: 1090), collapsedFrame: collapsed))
    }

    /// The pointer can sit exactly on the display's top edge, which a half-open `contains` misses.
    func testTheTopEdgeCounts() {
        XCTAssertTrue(NotchHover.shouldExpand(pointer: CGPoint(x: 855, y: collapsed.maxY), collapsedFrame: collapsed))
        XCTAssertTrue(NotchHover.shouldExpand(pointer: CGPoint(x: collapsed.minX, y: collapsed.maxY), collapsedFrame: collapsed))
    }

    func testTheHotZoneIsOnlyALittleBiggerThanThePanel() {
        let inset = NotchHover.hotZoneInset
        XCTAssertTrue(NotchHover.shouldExpand(pointer: CGPoint(x: collapsed.minX - inset, y: 1090), collapsedFrame: collapsed))
        XCTAssertFalse(NotchHover.shouldExpand(pointer: CGPoint(x: collapsed.minX - inset - 1, y: 1090), collapsedFrame: collapsed))
        XCTAssertFalse(NotchHover.shouldExpand(pointer: CGPoint(x: collapsed.maxX + inset + 1, y: 1090), collapsedFrame: collapsed))
        XCTAssertFalse(NotchHover.shouldExpand(pointer: CGPoint(x: 855, y: collapsed.minY - inset - 1), collapsedFrame: collapsed))
    }

    func testAPointerFarAwayDoesNothing() {
        XCTAssertFalse(NotchHover.shouldExpand(pointer: CGPoint(x: 100, y: 100), collapsedFrame: collapsed))
    }

    func testItStaysOpenWhileThePointerIsOnOrJustOutsideThePanel() {
        XCTAssertFalse(NotchHover.shouldCollapse(pointer: CGPoint(x: 855, y: 950), expandedFrame: expanded))
        let margin = NotchHover.collapseMargin
        XCTAssertFalse(NotchHover.shouldCollapse(pointer: CGPoint(x: expanded.minX - margin, y: 950), expandedFrame: expanded))
        XCTAssertFalse(NotchHover.shouldCollapse(pointer: CGPoint(x: 855, y: expanded.minY - margin), expandedFrame: expanded))
    }

    func testItClosesOnceThePointerIsClearlyAway() {
        let margin = NotchHover.collapseMargin
        XCTAssertTrue(NotchHover.shouldCollapse(pointer: CGPoint(x: expanded.minX - margin - 1, y: 950), expandedFrame: expanded))
        XCTAssertTrue(NotchHover.shouldCollapse(pointer: CGPoint(x: expanded.maxX + margin + 1, y: 950), expandedFrame: expanded))
        XCTAssertTrue(NotchHover.shouldCollapse(pointer: CGPoint(x: 855, y: expanded.minY - margin - 1), expandedFrame: expanded))
    }

    func testTheTopOfTheDisplayNeverClosesIt() {
        // Above the open panel is off the display; moving up to the very edge must not close it.
        XCTAssertFalse(NotchHover.shouldCollapse(pointer: CGPoint(x: 855, y: expanded.maxY + 50), expandedFrame: expanded))
    }

    func testTheWingGrowsForLongPositions() {
        XCTAssertEqual(NotchGeometry.wing(forPositionText: nil), NotchGeometry.collapsedWing)
        XCTAssertEqual(NotchGeometry.wing(forPositionText: "1/9"), NotchGeometry.collapsedWing)
        XCTAssertEqual(NotchGeometry.wing(forPositionText: "12/48"), NotchGeometry.collapsedWing)
        XCTAssertEqual(NotchGeometry.wing(forPositionText: "12/150"), NotchGeometry.collapsedWing + 10)
        XCTAssertEqual(NotchGeometry.wing(forPositionText: "123/456"), NotchGeometry.collapsedWing + 10)
        XCTAssertEqual(NotchGeometry.wing(forPositionText: "1234/5678"), NotchGeometry.collapsedWing + 20)
    }
}

final class DirectoryWatcherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReportsAFileBeingWritten() throws {
        let changed = expectation(description: "change reported")
        changed.assertForOverFulfill = false
        let watcher = try XCTUnwrap(DirectoryWatcher(directory: directory, coalescing: 0.02) { changed.fulfill() })
        addTeardownBlock { watcher.cancel() }

        try Data("x".utf8).write(to: directory.appendingPathComponent("playback.json"), options: .atomic)
        wait(for: [changed], timeout: 3)
    }

    func testAnAtomicReplaceOfAnExistingFileIsNoticed() throws {
        let file = directory.appendingPathComponent("playback.json")
        try Data("one".utf8).write(to: file)
        let changed = expectation(description: "replace reported")
        changed.assertForOverFulfill = false
        let watcher = try XCTUnwrap(DirectoryWatcher(directory: directory, coalescing: 0.02) { changed.fulfill() })
        addTeardownBlock { watcher.cancel() }

        try Data("two".utf8).write(to: file, options: .atomic) // what PlaybackStorage does
        wait(for: [changed], timeout: 3)
    }

    func testABurstOfEventsIsReportedOnce() throws {
        var calls = 0
        let settled = expectation(description: "burst settled")
        let watcher = try XCTUnwrap(DirectoryWatcher(directory: directory, coalescing: 0.2) {
            calls += 1
            settled.fulfill()
        })
        addTeardownBlock { watcher.cancel() }

        for i in 0..<5 { try Data("\(i)".utf8).write(to: directory.appendingPathComponent("f\(i).json"), options: .atomic) }
        wait(for: [settled], timeout: 3)
        // Give any stray second report time to arrive.
        let quiet = expectation(description: "quiet")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { quiet.fulfill() }
        wait(for: [quiet], timeout: 2)
        XCTAssertEqual(calls, 1)
    }

    func testNothingIsReportedWhileNothingChanges() throws {
        let silent = expectation(description: "no report")
        silent.isInverted = true
        let watcher = try XCTUnwrap(DirectoryWatcher(directory: directory, coalescing: 0.02) { silent.fulfill() })
        addTeardownBlock { watcher.cancel() }
        wait(for: [silent], timeout: 0.6)
    }

    func testCancelStopsReports() throws {
        let silent = expectation(description: "no report after cancel")
        silent.isInverted = true
        let watcher = try XCTUnwrap(DirectoryWatcher(directory: directory, coalescing: 0.02) { silent.fulfill() })
        watcher.cancel()
        try Data("x".utf8).write(to: directory.appendingPathComponent("late.json"))
        wait(for: [silent], timeout: 0.6)
    }
}

@MainActor
final class NotchControllerTests: XCTestCase {
    private var root: URL!
    private let notched = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073.5),
        safeAreaTop: 33.5,
        auxiliaryTopLeft: CGRect(x: 0, y: 1073.5, width: 762.5, height: 33.5),
        auxiliaryTopRight: CGRect(x: 947.5, y: 1073.5, width: 762.5, height: 33.5)
    )
    private let external = ScreenMetrics(
        frame: CGRect(x: 1710, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1710, y: 0, width: 2560, height: 1415),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Rig {
        var controller: NotchController
        var decks: DeckStore
        var playback: PlaybackStore
    }

    /// A controller wired to throwaway stores in a temp folder, never to the real library.
    private func makeRig(
        decks: [Deck] = [],
        displays: @escaping @MainActor () -> [ScreenMetrics],
        monitors: Bool = false,
        expandDelay: Duration = .milliseconds(10),
        collapseDelay: Duration = .milliseconds(10),
        collapseAnimation: Duration = .milliseconds(10)
    ) throws -> Rig {
        if !decks.isEmpty { try DeckStorage(directory: root).save(decks) }
        let deckStore = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let controller = NotchController(
            placementProvider: {
                let screens = displays()
                return NotchGeometry.chooseScreen(screens).map { NotchGeometry.placement(for: screens[$0]) }
            },
            showsPanel: false,
            installsMonitors: monitors,
            expandDelay: expandDelay,
            collapseDelay: collapseDelay,
            collapseAnimation: collapseAnimation,
            watchDirectory: root,
            deckStore: { deckStore },
            playbackStore: { playback },
            settingsStore: { settings }
        )
        addTeardownBlock { controller.stop() }
        return Rig(controller: controller, decks: deckStore, playback: playback)
    }

    private func sampleDeck(cards: Int = 48) -> Deck {
        Deck(name: "Everyday Spanish", color: .green, cards: (1...cards).map { Card(front: "front \($0)", back: "back \($0)") })
    }

    // MARK: Placement and click-through

    func testStartPutsThePanelOverTheNotch() throws {
        let rig = try makeRig(decks: [sampleDeck()]) { [notched] in [notched] }
        rig.controller.start()
        XCTAssertEqual(rig.controller.panel?.frame, rig.controller.collapsedFrame)
    }

    func testAtRestClicksPassThroughToWhateverIsUnderneath() throws {
        let rig = try makeRig(decks: [sampleDeck()]) { [notched] in [notched] }
        rig.controller.start()
        XCTAssertEqual(rig.controller.panel?.ignoresMouseEvents, true)
        XCTAssertFalse(rig.controller.model.isExpanded)
    }

    func testThePanelFollowsDisplayChanges() throws {
        var displays = [notched]
        let rig = try makeRig(decks: [sampleDeck()]) { displays }
        rig.controller.start()
        let atNotch = try XCTUnwrap(rig.controller.panel?.frame)

        displays = [external]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let onExternal = try XCTUnwrap(rig.controller.panel?.frame)
        XCTAssertNotEqual(onExternal, atNotch)
        XCTAssertEqual(onExternal.midX, external.frame.midX, accuracy: 0.5)

        displays = [notched, external]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(rig.controller.panel?.frame, atNotch)
    }

    func testAnOpenPanelStaysCenteredOnADisplayChange() throws {
        var displays = [notched]
        let rig = try makeRig(decks: [sampleDeck()]) { displays }
        rig.controller.start()
        rig.controller.expand()

        displays = [external]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(rig.controller.panel?.frame, rig.controller.expandedFrame)
        XCTAssertEqual(rig.controller.panel?.frame.midX ?? 0, external.frame.midX, accuracy: 0.5)
    }

    /// A hosting view that is the window's own content view resizes the window to fit its largest
    /// child, so the panel could never shrink back to the thin resting strip (seen in the real app).
    func testTheSwiftUIViewIsNotTheWindowsContentView() throws {
        let rig = try makeRig(decks: [sampleDeck()]) { [notched] in [notched] }
        rig.controller.start()
        let content = try XCTUnwrap(rig.controller.panel?.contentView)
        XCTAssertFalse(content is NSHostingView<NotchRootView>)
        XCTAssertTrue(content.subviews.contains { $0 is NSHostingView<NotchRootView> })
    }

    func testStartingTwiceMakesOnePanelAndStopRemovesIt() throws {
        let rig = try makeRig(decks: [sampleDeck()]) { [notched] in [notched] }
        rig.controller.start()
        let first = rig.controller.panel
        rig.controller.start()
        XCTAssertTrue(rig.controller.panel === first)
        rig.controller.stop()
        XCTAssertNil(rig.controller.panel)
    }

    func testNoDisplayLeavesThePanelWhereItWasWithoutCrashing() throws {
        var displays = [notched]
        let rig = try makeRig(decks: [sampleDeck()]) { displays }
        rig.controller.start()
        let before = rig.controller.panel?.frame
        displays = []
        rig.controller.reposition()
        XCTAssertEqual(rig.controller.panel?.frame, before)
    }

    // MARK: Hover

    func testHoveringOpensItAndItTakesMouseEvents() async throws {
        let rig = try makeRig(decks: [sampleDeck()]) { [notched] in [notched] }
        rig.controller.start()
        let collapsed = try XCTUnwrap(rig.controller.collapsedFrame)

        rig.controller.handlePointer(CGPoint(x: collapsed.midX, y: collapsed.midY))
        await rig.controller.pendingExpand?.value

        XCTAssertTrue(rig.controller.model.isExpanded)
        XCTAssertEqual(rig.controller.panel?.ignoresMouseEvents, false, "open, so its buttons can be clicked")
        XCTAssertEqual(rig.controller.panel?.frame, rig.controller.expandedFrame)
    }

    func testAPointerThatJustFliesByNeverOpensIt() async throws {
        let rig = try makeRig(decks: [sampleDeck()], displays: { [notched] in [notched] })
        rig.controller.start()
        let collapsed = try XCTUnwrap(rig.controller.collapsedFrame)

        rig.controller.handlePointer(CGPoint(x: collapsed.midX, y: collapsed.midY))
        XCTAssertNotNil(rig.controller.pendingExpand)
        rig.controller.handlePointer(CGPoint(x: 100, y: 100)) // gone before the dwell elapsed
        XCTAssertNil(rig.controller.pendingExpand)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(rig.controller.model.isExpanded)
    }

    func testMovingAwayClosesItAndHandsClicksBack() async throws {
        let rig = try makeRig(decks: [sampleDeck()]) { [notched] in [notched] }
        rig.controller.start()
        let collapsed = try XCTUnwrap(rig.controller.collapsedFrame)
        rig.controller.handlePointer(CGPoint(x: collapsed.midX, y: collapsed.midY))
        await rig.controller.pendingExpand?.value

        rig.controller.handlePointer(CGPoint(x: 100, y: 100))
        await rig.controller.pendingCollapse?.value
        XCTAssertFalse(rig.controller.model.isExpanded)
        await rig.controller.pendingFinishCollapse?.value

        XCTAssertEqual(rig.controller.panel?.ignoresMouseEvents, true, "collapsed again: clicks pass through")
        XCTAssertEqual(rig.controller.panel?.frame, rig.controller.collapsedFrame)
    }

    func testBrushingTheEdgeDoesNotClose() async throws {
        let rig = try makeRig(decks: [sampleDeck()]) { [notched] in [notched] }
        rig.controller.start()
        rig.controller.expand()
        let expanded = try XCTUnwrap(rig.controller.expandedFrame)

        rig.controller.handlePointer(CGPoint(x: expanded.minX - 5, y: expanded.midY)) // inside the margin
        XCTAssertNil(rig.controller.pendingCollapse)
        XCTAssertTrue(rig.controller.model.isExpanded)
    }

    func testComingBackBeforeItClosesKeepsItOpen() async throws {
        let rig = try makeRig(decks: [sampleDeck()], displays: { [notched] in [notched] }, collapseDelay: .milliseconds(80))
        rig.controller.start()
        rig.controller.expand()
        let expanded = try XCTUnwrap(rig.controller.expandedFrame)

        rig.controller.handlePointer(CGPoint(x: 100, y: 100))
        XCTAssertNotNil(rig.controller.pendingCollapse)
        rig.controller.handlePointer(CGPoint(x: expanded.midX, y: expanded.midY))
        XCTAssertNil(rig.controller.pendingCollapse)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(rig.controller.model.isExpanded)
    }

    func testReopeningDuringTheCloseAnimationKeepsClicksWorking() async throws {
        let rig = try makeRig(decks: [sampleDeck()], displays: { [notched] in [notched] }, collapseAnimation: .milliseconds(80))
        rig.controller.start()
        rig.controller.expand()
        rig.controller.collapse()
        rig.controller.expand() // back before the animation finished
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(rig.controller.model.isExpanded)
        XCTAssertEqual(rig.controller.panel?.ignoresMouseEvents, false)
    }

    // MARK: No Accessibility permission needed

    func testThePointerMonitorsInstallWithoutAccessibilityPermission() throws {
        let rig = try makeRig(decks: [sampleDeck()], displays: { [notched] in [notched] }, monitors: true)
        rig.controller.start()
        XCTAssertTrue(rig.controller.hasPointerMonitors, "mouse-moved monitors need no Accessibility permission")
        rig.controller.stop()
        XCTAssertFalse(rig.controller.hasPointerMonitors)
    }

    // MARK: What it shows

    func testAtRestItShowsTheFirstDecksIconAndPosition() throws {
        let rig = try makeRig(decks: [sampleDeck(), Deck(name: "Other", cards: [Card(front: "x", back: "y")])]) { [notched] in [notched] }
        rig.controller.start()
        rig.controller.refreshContent(at: Date(timeIntervalSince1970: 11 * 300)) // slot 11: card 12
        let showing = try XCTUnwrap(rig.controller.model.showing)
        XCTAssertEqual(showing.deckName, "Everyday Spanish")
        XCTAssertEqual(showing.deckColor, .green)
        XCTAssertEqual(showing.positionText, "12/48")
    }

    func testEditsToTheLibraryShowUpImmediately() async throws {
        let rig = try makeRig(decks: [sampleDeck(cards: 3)]) { [notched] in [notched] }
        rig.controller.start()
        let at = Date(timeIntervalSince1970: 0)
        rig.controller.refreshContent(at: at)
        XCTAssertEqual(rig.controller.model.showing?.positionText, "1/3")

        rig.decks.addCard(to: rig.decks.decks[0].id)
        rig.controller.refreshContent(at: at)
        XCTAssertEqual(rig.controller.model.showing?.positionText, "1/4")
    }

    func testASkipMovesTheShownCard() throws {
        let rig = try makeRig(decks: [sampleDeck(cards: 10)]) { [notched] in [notched] }
        rig.controller.start()
        let at = Date(timeIntervalSince1970: 0)
        rig.playback.skip(rig.decks.decks[0], at: at)
        rig.controller.refreshContent(at: at)
        XCTAssertEqual(rig.controller.model.showing?.positionText, "2/10")
    }

    func testTheRestingPanelGrowsForLongPositions() throws {
        let rig = try makeRig(decks: [sampleDeck(cards: 200)]) { [notched] in [notched] }
        rig.controller.start()
        rig.controller.refreshContent(at: Date(timeIntervalSince1970: 99 * 300)) // "100/200"
        let wide = try XCTUnwrap(rig.controller.panel?.frame.width)

        rig.controller.refreshContent(at: Date(timeIntervalSince1970: 0)) // "1/200"
        let narrow = try XCTUnwrap(rig.controller.panel?.frame.width)
        XCTAssertGreaterThan(wide, narrow)
        XCTAssertEqual(rig.controller.panel?.frame.midX ?? 0, notched.frame.midX, accuracy: 0.5, "still centered on the camera")
    }

    func testWithNoDecksItStaysAPlainBlackExtensionOfTheNotch() throws {
        let rig = try makeRig(displays: { [notched] in [notched] })
        rig.controller.start()
        XCTAssertNil(rig.controller.model.showing)
        XCTAssertEqual(rig.controller.panel?.ignoresMouseEvents, true)
    }

    func testTheAccentFollowsTheSetting() throws {
        let rig = try makeRig(decks: [sampleDeck()]) { [notched] in [notched] }
        rig.controller.start()
        XCTAssertEqual(rig.controller.model.accent, .indigo)
    }
}

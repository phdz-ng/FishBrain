import AppKit
import SwiftUI
import XCTest

// FLAS-89: card text in the resting notch.

/// FLAS-90: the drawn notch is the size of a real MacBook notch.
final class CardNotchGeometryTests: XCTestCase {
    /// A display without a notch and a 24 pt menu bar.
    private let plain = ScreenMetrics(
        frame: CGRect(x: 1710, y: -200, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1710, y: -200, width: 2560, height: 1416),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )
    private let notched = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073.5),
        safeAreaTop: 33.5,
        auxiliaryTopLeft: CGRect(x: 0, y: 1073.5, width: 762.5, height: 33.5),
        auxiliaryTopRight: CGRect(x: 947.5, y: 1073.5, width: 762.5, height: 33.5)
    )

    func testTheDrawnCardNotchIs200By32AndFlushWithTheTopOfA24PointMenuBar() {
        let frame = NotchGeometry.placement(for: plain).alignedCardFrame()
        XCTAssertEqual(frame.size, CGSize(width: 200, height: 32))
        XCTAssertEqual(frame.maxY, plain.frame.maxY, "flush with the top")
        XCTAssertEqual(plain.frame.maxY - frame.minY - 24, 8, "hangs 8 pt below the menu bar, like a real notch")
        XCTAssertEqual(frame.midX, plain.frame.midX, accuracy: 0.5, "centered")
        XCTAssertEqual(frame, frame.integral, "whole points")
        XCTAssertEqual(NotchGeometry.cardRestSize, CGSize(width: 200, height: 32))
        XCTAssertEqual(NotchGeometry.drawnWidth(forPositionText: "12/48", style: .card), 200)
    }

    func testTheCardTextGets176PointsWhenDrawnAnd76BesideTheCamera() {
        XCTAssertEqual(CardRestLayout.drawn.textWidth, 176)
        XCTAssertEqual(CardRestLayout.besideCamera.textWidth, 76)
        XCTAssertNil(CardRestLayout.deckOnly.textWidth)
    }

    func testBesideARealNotchTheLeftWingIs92AndTheRightWing34() {
        let placement = NotchGeometry.placement(for: notched)
        XCTAssertEqual(placement.cardLayout, .besideCamera)
        let frame = placement.alignedSnugFrame()
        XCTAssertEqual(frame.width, placement.notchFrame.width + 92 + 34, accuracy: 1)
        XCTAssertEqual(frame.minX, placement.notchFrame.minX - 92, accuracy: 0.5)
        XCTAssertEqual(frame.maxX, placement.notchFrame.maxX + 34, accuracy: 0.5)
        XCTAssertEqual(frame.height, 33, "as tall as the notch, rounded down")
        XCTAssertEqual(frame.maxY, notched.frame.maxY)
    }

    func testANarrowLeftMenuBarStripFallsBackToTheDeckColorOnly() {
        var narrow = notched
        narrow.auxiliaryTopLeft = CGRect(x: 0, y: 1073.5, width: 250, height: 33.5)
        narrow.auxiliaryTopRight = CGRect(x: 435, y: 1073.5, width: 250, height: 33.5)
        XCTAssertEqual(NotchGeometry.placement(for: narrow).cardLayout, .deckOnly)
        XCTAssertEqual(NotchGeometry.placement(for: plain).cardLayout, .drawn)
    }

    func testTheHoverZoneIsTheWholeCardNotch() {
        let frame = NotchGeometry.placement(for: plain).alignedCardFrame()
        XCTAssertTrue(NotchHover.shouldExpand(pointer: CGPoint(x: frame.minX + 1, y: frame.minY + 1), collapsedFrame: frame), "bottom-left corner")
        XCTAssertTrue(NotchHover.shouldExpand(pointer: CGPoint(x: frame.maxX - 1, y: frame.maxY), collapsedFrame: frame), "top-right, at the display edge")
        XCTAssertFalse(NotchHover.shouldExpand(pointer: CGPoint(x: frame.midX, y: frame.minY - 10), collapsedFrame: frame), "below it")
    }
}

/// FLAS-90 and FLAS-92: what each side shows and how long text fits.
final class CardNotchTextTests: XCTestCase {
    func testLineBreaksBecomeSpaces() {
        XCTAssertEqual(NotchCardRest.oneLine("What does\nthe mitochondria\r\n do?"), "What does the mitochondria do?")
        XCTAssertEqual(NotchCardRest.oneLine("  hola  "), "hola")
    }

    func testAPictureOnlySideShowsPictureAndAnEmptyBackShowsNothing() {
        let image = CardImage(fileName: "a.png")
        let card = Card(front: "", back: "", frontImage: image)
        let faces = NotchCardRest.faces(of: card)
        XCTAssertEqual(faces.front, .picture)
        XCTAssertEqual(faces.back, .empty)
        XCTAssertEqual(NotchCardRest.face(text: "  la manzana ", hasImage: true), .text("la manzana"), "text wins over a picture")
        XCTAssertEqual(NotchCardRest.accessibilityLabel(for: card), "Card: Picture")
    }

    func testVoiceOverReadsTheFront() {
        XCTAssertEqual(NotchCardRest.accessibilityLabel(for: Card(front: "la manzana", back: "the apple")), "Card: la manzana")
    }

    func testShortTextFitsAt12Points() {
        XCTAssertEqual(NotchCardRest.fit(naturalWidth: 120, available: 176, reduceMotion: false), .fits(fontSize: 12))
    }

    func testTextThatFitsAt11PointsShrinksAndDoesNotSlide() {
        let fit = NotchCardRest.fit(naturalWidth: 190, available: 176, reduceMotion: false) // 174 at 11 pt
        XCTAssertEqual(fit, .fits(fontSize: 11))
        XCTAssertEqual(NotchCardRest.slideDuration(fit), 0)
    }

    func testLongTextSlidesAt30PointsASecondAfterASecond() {
        let fit = NotchCardRest.fit(naturalWidth: 288, available: 176, reduceMotion: false) // 264 at 11 pt
        XCTAssertEqual(fit, .slides(fontSize: 11, overflow: 88))
        XCTAssertEqual(NotchCardRest.slideOffset(fit, elapsed: 0.5), 0, "waits a second first")
        XCTAssertEqual(NotchCardRest.slideOffset(fit, elapsed: 2), -30, accuracy: 0.01)
        XCTAssertEqual(NotchCardRest.slideOffset(fit, elapsed: 60), -88, "holds once its end shows")
        XCTAssertEqual(NotchCardRest.slideDuration(fit), 1 + 88.0 / 30, accuracy: 0.001)
    }

    func testWithReduceMotionLongTextIsCutOffInstead() {
        XCTAssertEqual(NotchCardRest.fit(naturalWidth: 288, available: 176, reduceMotion: true), .truncates(fontSize: 11))
        XCTAssertEqual(NotchCardRest.fit(naturalWidth: 120, available: 176, reduceMotion: true), .fits(fontSize: 12))
    }

    func testMeasuredTextAgreesWithTheRules() {
        XCTAssertEqual(CardPillContent.fit(.text("la manzana"), width: 176, reduceMotion: false), .fits(fontSize: 12))
        let long = CardPillContent.fit(.text("What does the mitochondria do in a eukaryotic cell?"), width: 176, reduceMotion: false)
        guard case .slides(11, let overflow) = long else { return XCTFail("expected it to slide, got \(long)") }
        XCTAssertGreaterThan(overflow, 0)
        XCTAssertEqual(CardPillContent.fit(.picture, width: 76, reduceMotion: false), .fits(fontSize: 12))
    }
}

/// FLAS-91 and FLAS-94: when the resting card flips.
final class CardNotchFlipTests: XCTestCase {
    func testItShowsTheFrontThenTheAnswerEveryFiveSeconds() {
        let plan = NotchCardRest.FlipPlan(interval: .five, hasBack: true)
        XCTAssertEqual(plan.side(at: 0), .front)
        XCTAssertEqual(plan.side(at: 4.9), .front)
        XCTAssertEqual(plan.side(at: 5), .back)
        XCTAssertEqual(plan.side(at: 9.9), .back)
        XCTAssertEqual(plan.side(at: 10), .front)
        XCTAssertEqual(plan.nextChange(after: 0), 5)
        XCTAssertEqual(plan.nextChange(after: 5), 10)
        XCTAssertEqual(plan.nextChange(after: 12), 15)
    }

    func testTheIntervalSettingIsUsed() {
        XCTAssertEqual(NotchCardRest.FlipPlan(interval: .three, hasBack: true).side(at: 3), .back)
        XCTAssertEqual(NotchCardRest.FlipPlan(interval: .ten, hasBack: true).side(at: 5), .front)
        XCTAssertEqual(NotchCardRest.FlipPlan(interval: .ten, hasBack: true).side(at: 10), .back)
    }

    func testOffNeverFlips() {
        let plan = NotchCardRest.FlipPlan(interval: .off, hasBack: true)
        XCTAssertFalse(plan.flips)
        for t in stride(from: 0.0, through: 60, by: 2.5) { XCTAssertEqual(plan.side(at: t), .front) }
        XCTAssertNil(plan.nextChange(after: 0))
    }

    func testAnEmptyBackNeverFlips() {
        let plan = NotchCardRest.FlipPlan(interval: .five, hasBack: false)
        XCTAssertFalse(plan.flips)
        XCTAssertEqual(plan.side(at: 5), .front)
        XCTAssertEqual(plan.side(at: 12), .front)
    }

    func testASideThatSlidesLongerThanTheIntervalStaysUntilTheSlideEndsPlusASecond() {
        // The front takes 1 s + 6 s to slide, so it stays 8 s; the back is short and keeps 5 s.
        let plan = NotchCardRest.FlipPlan(interval: .five, hasBack: true, frontSlide: 7, backSlide: 0)
        XCTAssertEqual(plan.frontHold, 8)
        XCTAssertEqual(plan.backHold, 5)
        XCTAssertEqual(plan.side(at: 7.9), .front)
        XCTAssertEqual(plan.side(at: 8), .back)
        XCTAssertEqual(plan.side(at: 13), .front)
        XCTAssertEqual(plan.timeIntoSide(at: 9), 1, accuracy: 0.001)
        // A slide shorter than the interval doesn't stretch it.
        XCTAssertEqual(NotchCardRest.FlipPlan(interval: .five, hasBack: true, frontSlide: 2).frontHold, 5)
    }

    func testReduceMotionFadesInsteadOfTurning() {
        XCTAssertEqual(NotchCardRest.flipStyle(reduceMotion: true), .crossfade)
        XCTAssertEqual(NotchCardRest.flipDuration(reduceMotion: true), 0.3)
        XCTAssertEqual(NotchCardRest.flipStyle(reduceMotion: false), .rotate)
        XCTAssertEqual(NotchCardRest.flipDuration(reduceMotion: false), 0.5)
    }

    func testTheScheduleWakesOnlyWhenTheSideChanges() {
        let start = Date(timeIntervalSince1970: 1000)
        let schedule = CardFlipSchedule(plan: NotchCardRest.FlipPlan(interval: .five, hasBack: true), start: start)
        let dates = Array(schedule.entries(from: start, mode: .normal).prefix(4))
        XCTAssertEqual(dates.map { $0.timeIntervalSince(start) }, [0, 5, 10, 15])
        let off = CardFlipSchedule(plan: NotchCardRest.FlipPlan(interval: .off, hasBack: true), start: start)
        XCTAssertEqual(Array(off.entries(from: start, mode: .normal).prefix(4)).count, 1, "nothing to wake for")
    }
}

/// FLAS-94: the Card style, its default, the migration and the flip setting.
final class CardPillStyleSettingsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCardIsTheDefaultAndListedFirst() {
        XCTAssertEqual(AppSettings().pillStyle, .card)
        XCTAssertEqual(PillStyle.available.first, .card)
        XCTAssertEqual(PillStyle.card.displayName, "Card")
        XCTAssertEqual(PillStyle.card.summary, "The card you're learning, flipping between front and answer.")
        XCTAssertNotNil(NSImage(systemSymbolName: PillStyle.card.symbolName, accessibilityDescription: nil))
    }

    func testARealNotchShowsCardOnlyWhenCardIsPicked() {
        XCTAssertEqual(PillStyle.onRealNotch(.card), .card)
        for style in [PillStyle.classic, .fish, .streak, .session] { XCTAssertEqual(PillStyle.onRealNotch(style), .classic) }
    }

    func testTheFlipIntervalDefaultsToFiveSecondsWhenMissing() throws {
        XCTAssertEqual(AppSettings().notchFlipInterval, .five)
        let storage = SettingsStorage(directory: directory)
        try Data(#"{"accent":"teal","pillStyle":"card"}"#.utf8).write(to: storage.fileURL)
        XCTAssertEqual(storage.load().notchFlipInterval, .five)
        XCTAssertEqual(try JSONDecoder().decode(NotchFlipInterval.self, from: Data("7".utf8)), .five, "an unknown value too")
        XCTAssertEqual(NotchFlipInterval.choices.map(\.displayName), ["3 seconds", "5 seconds", "10 seconds", "Off"])
        XCTAssertNil(NotchFlipInterval.off.seconds)
    }

    func testTheFlipIntervalRoundTrips() throws {
        let storage = SettingsStorage(directory: directory)
        try storage.save(AppSettings(notchFlipInterval: .ten))
        XCTAssertEqual(storage.load().notchFlipInterval, .ten)
    }

    func testTheMigrationMovesClassicToCardAndKeepsTheOthers() {
        for (stored, expected) in [(PillStyle.classic, PillStyle.card), (.fish, .fish), (.streak, .streak), (.session, .session)] {
            var settings = AppSettings(pillStyle: stored, didMigratePillStyleCard1: false)
            XCTAssertTrue(settings.migratePillStyleToCard())
            XCTAssertEqual(settings.pillStyle, expected)
            XCTAssertTrue(settings.didMigratePillStyleCard1)
        }
    }

    func testTheMigrationRunsOnce() {
        var settings = AppSettings(pillStyle: .classic, didMigratePillStyleCard1: false)
        XCTAssertTrue(settings.migratePillStyleToCard())
        settings.pillStyle = .classic // picked again on purpose afterwards
        XCTAssertFalse(settings.migratePillStyleToCard(), "running it twice changes nothing")
        XCTAssertEqual(settings.pillStyle, .classic)
    }

    @MainActor
    func testAnOlderSettingsFileOnClassicMovesToCardOnLaunchAndStaysPut() throws {
        let storage = SettingsStorage(directory: directory)
        try Data(#"{"accent":"teal","pillStyle":"classic"}"#.utf8).write(to: storage.fileURL)
        XCTAssertEqual(SettingsStore(storage: storage, onSaved: {}).pillStyle, .card)
        XCTAssertTrue(storage.load().didMigratePillStyleCard1, "saved, so it won't run again")
        XCTAssertEqual(storage.load().accent, .teal, "nothing else changes")

        let store = SettingsStore(storage: storage, onSaved: {})
        store.pillStyle = .classic
        XCTAssertEqual(SettingsStore(storage: storage, onSaved: {}).pillStyle, .classic, "a later choice of Classic is kept")
    }

    @MainActor
    func testAnOlderFileWithoutAStyleAlsoGetsCard() throws {
        let storage = SettingsStorage(directory: directory)
        try Data(#"{"accent":"teal"}"#.utf8).write(to: storage.fileURL)
        XCTAssertEqual(SettingsStore(storage: storage, onSaved: {}).pillStyle, .card)
    }

    @MainActor
    func testAnOlderFileOnFishKeepsFish() throws {
        let storage = SettingsStorage(directory: directory)
        try Data(#"{"pillStyle":"fish"}"#.utf8).write(to: storage.fileURL)
        XCTAssertEqual(SettingsStore(storage: storage, onSaved: {}).pillStyle, .fish)
    }

    @MainActor
    func testANewInstallSavesNothingAtLaunch() {
        _ = SettingsStore(storage: SettingsStorage(directory: directory), onSaved: {})
        XCTAssertFalse(FileManager.default.fileExists(atPath: SettingsStorage(directory: directory).fileURL.path))
    }

    @MainActor
    func testTheFlipSettingSavesWithoutReloadingWidgets() {
        var reloads = 0
        let storage = SettingsStorage(directory: directory)
        let store = SettingsStore(storage: storage, onSaved: { reloads += 1 })
        store.notchFlipInterval = .off
        XCTAssertEqual(storage.load().notchFlipInterval, .off)
        XCTAssertEqual(reloads, 0)
    }
}

/// FLAS-90, FLAS-91 and FLAS-93 through the notch controller.
@MainActor
final class CardNotchControllerTests: XCTestCase {
    private var root: URL!
    private var now = Date(timeIntervalSince1970: 0)
    private var playbackSaves = 0
    private var widgetReloads = 0

    private let plain = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, displayID: 1, isBuiltIn: true
    )
    private let notched = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073.5),
        safeAreaTop: 33.5,
        auxiliaryTopLeft: CGRect(x: 0, y: 1073.5, width: 762.5, height: 33.5),
        auxiliaryTopRight: CGRect(x: 947.5, y: 1073.5, width: 762.5, height: 33.5)
    )

    private struct Rig {
        var controller: NotchController
        var decks: DeckStore
        var playback: PlaybackStore
        var settings: SettingsStore
        var copy: CopyOfferStore
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        now = Date(timeIntervalSince1970: 0)
        playbackSaves = 0
        widgetReloads = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRig(screen: ScreenMetrics? = nil, decks: [Deck]? = nil) throws -> Rig {
        let screen = screen ?? plain
        try DeckStorage(directory: root).save(decks ?? [Deck(
            name: "Spanish", color: .green,
            cards: (1...40).map { Card(front: "front \($0)", back: "back \($0)") }
        )])
        let deckStore = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: { [unowned self] in widgetReloads += 1 })
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: { [unowned self] in playbackSaves += 1 })
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: { [unowned self] in widgetReloads += 1 })
        let copy = CopyOfferStore()
        let controller = NotchController(
            placementProvider: { NotchGeometry.placement(for: screen) },
            showsPanel: false, installsMonitors: false,
            expandDelay: .milliseconds(5), collapseDelay: .milliseconds(5), collapseAnimation: .milliseconds(5),
            watchDirectory: root, clock: { [unowned self] in now },
            deckStore: { deckStore }, playbackStore: { playback }, settingsStore: { settings },
            copyStore: { copy }
        )
        addTeardownBlock { controller.stop() }
        controller.start()
        return Rig(controller: controller, decks: deckStore, playback: playback, settings: settings, copy: copy)
    }

    func testTheDrawnRestingPanelIsTheCardNotch() throws {
        let rig = try makeRig()
        XCTAssertEqual(rig.controller.model.restStyle, .card, "the default")
        let frame = try XCTUnwrap(rig.controller.collapsedFrame)
        XCTAssertEqual(frame.size, CGSize(width: 200, height: 32))
        XCTAssertEqual(frame.maxY, plain.frame.maxY)
        XCTAssertEqual(frame.midX, plain.frame.midX, accuracy: 0.5)
        XCTAssertEqual(rig.controller.panel?.frame, frame, "the panel is that size")
        XCTAssertEqual(rig.controller.model.collapsedSize, frame.size)
        XCTAssertEqual(rig.controller.model.cardLayout, .drawn)
    }

    func testTheOfferBannerStillTakesOverTheCardNotch() throws {
        let rig = try makeRig()
        rig.copy.offer(text: "sin embargo", at: now)
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.collapsedFrame?.width, NotchGeometry.bannerRestWidth)
        rig.copy.dismiss()
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.collapsedFrame?.size, CGSize(width: 200, height: 32))
    }

    func testOtherStylesKeepTheirFrames() throws {
        let rig = try makeRig()
        rig.settings.pillStyle = .classic
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.collapsedFrame?.width, NotchGeometry.drawnRestWidth)
        XCTAssertEqual(rig.controller.collapsedFrame?.height, 24, "Classic stays as tall as the menu bar")
    }

    func testBesideARealNotchTheTextWingIs92() throws {
        let rig = try makeRig(screen: notched)
        let placement = NotchGeometry.placement(for: notched)
        XCTAssertEqual(rig.controller.model.restStyle, .card)
        XCTAssertEqual(rig.controller.model.cardLayout, .besideCamera)
        let frame = try XCTUnwrap(rig.controller.collapsedFrame)
        XCTAssertEqual(frame.width, placement.notchFrame.width + 92 + 34, accuracy: 1)
        XCTAssertEqual(frame.height, 33)
    }

    func testClassicFishStreakAndSessionKeepTodaysFrameOnARealNotch() throws {
        let rig = try makeRig(screen: notched)
        let today = NotchGeometry.placement(for: notched).alignedCollapsedFrame(wing: NotchGeometry.wing(forPositionText: "1/40"))
        for style in [PillStyle.classic, .fish, .streak, .session] {
            rig.settings.pillStyle = style
            rig.controller.refreshContent()
            XCTAssertEqual(rig.controller.model.restStyle, .classic)
            XCTAssertEqual(rig.controller.collapsedFrame, today, "\(style)")
        }
    }

    func testANarrowMenuBarStripKeepsThe34PointWing() throws {
        var narrow = notched
        narrow.auxiliaryTopLeft = CGRect(x: 0, y: 1073.5, width: 250, height: 33.5)
        narrow.auxiliaryTopRight = CGRect(x: 435, y: 1073.5, width: 250, height: 33.5)
        let rig = try makeRig(screen: narrow)
        XCTAssertEqual(rig.controller.model.cardLayout, .deckOnly)
        XCTAssertEqual(rig.controller.collapsedFrame, NotchGeometry.placement(for: narrow).alignedCollapsedFrame(wing: 34))
    }

    func testAnEmptyDeckShowsItsIcon() throws {
        let rig = try makeRig(decks: [Deck(name: "New", color: .purple, cards: [])])
        XCTAssertNil(rig.controller.model.showing)
        XCTAssertEqual(rig.controller.model.emptyDeckColor, .purple)
        XCTAssertEqual(rig.controller.collapsedFrame?.size, CGSize(width: 200, height: 32))
    }

    func testANewCardStartsOnTheFront() throws {
        let rig = try makeRig()
        XCTAssertEqual(rig.controller.model.restStartedAt, now)
        let plan = NotchCardRest.FlipPlan(interval: rig.controller.model.flipInterval, hasBack: true)

        now = now.addingTimeInterval(7) // the back is showing
        XCTAssertEqual(plan.side(at: now.timeIntervalSince(rig.controller.model.restStartedAt)), .back)
        rig.controller.skipCurrent()
        XCTAssertEqual(rig.controller.model.restStartedAt, now, "a skip starts the next card on its front")
        XCTAssertEqual(plan.side(at: now.timeIntervalSince(rig.controller.model.restStartedAt)), .front)

        now = now.addingTimeInterval(300) // the clock rotates the card
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.restStartedAt, now, "so does a rotation")

        let before = rig.controller.model.restStartedAt
        now = now.addingTimeInterval(2)
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.restStartedAt, before, "the same card keeps its count")
    }

    func testHoveringPausesTheFlipAndClosingRestartsOnTheFront() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.controller.model.restIsActive)
        rig.controller.expand()
        XCTAssertFalse(rig.controller.model.restIsActive, "paused while open")
        now = now.addingTimeInterval(12)
        rig.controller.collapse()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(rig.controller.model.restIsActive)
        XCTAssertEqual(rig.controller.model.restStartedAt, now, "the front, and the count starts again")
    }

    func testChangingTheFlipSpeedReachesTheNotch() throws {
        let rig = try makeRig()
        rig.settings.notchFlipInterval = .three
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.flipInterval, .three)
    }

    func testTheRestingFlipWritesNothingAndReloadsNoWidgets() throws {
        let rig = try makeRig()
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        for seconds in [0.0, 5, 10, 15, 20] {
            now = Date(timeIntervalSince1970: seconds)
            rig.controller.refreshContent()
            XCTAssertEqual(rig.controller.model.showing?.isFlipped, false, "the shared state is never flipped")
        }
        XCTAssertEqual(playbackSaves, 0, "nothing goes through PlaybackActions")
        XCTAssertEqual(widgetReloads, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), filesBefore, "no playback or study file written")
    }

    func testThePickerSaysWhereCardApplies() {
        var selection = PillStyle.card
        let picker = PillStylePicker(selection: .init(get: { selection }, set: { selection = $0 }), hasDrawnNotch: true)
        XCTAssertTrue(picker.note.contains("Card shows the text beside it"))
    }
}

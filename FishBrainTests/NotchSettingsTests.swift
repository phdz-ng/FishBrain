import AppKit
import XCTest

final class NotchSettingsStorageTests: XCTestCase {
    private var directory: URL!
    private var storage: SettingsStorage!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = SettingsStorage(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheNotchIsOnByDefaultAndShowsTheFirstDeck() {
        let settings = AppSettings()
        XCTAssertTrue(settings.showsNotch)
        XCTAssertNil(settings.notchDeckID, "no choice means the first deck")
        XCTAssertEqual(storage.load().showsNotch, true, "a missing file also means on")
    }

    func testTheNotchSettingsRoundTrip() throws {
        let id = UUID()
        try storage.save(AppSettings(accent: .teal, showsNotch: false, notchDeckID: id))
        let loaded = storage.load()
        XCTAssertEqual(loaded.accent, .teal)
        XCTAssertFalse(loaded.showsNotch)
        XCTAssertEqual(loaded.notchDeckID, id)
    }

    func testAnOlderSettingsFileWithoutTheNewKeysKeepsWorking() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"accent":"purple"}"#.utf8).write(to: storage.fileURL)
        let loaded = storage.load()
        XCTAssertEqual(loaded.accent, .purple, "what was there is kept")
        XCTAssertTrue(loaded.showsNotch, "the notch defaults to on")
        XCTAssertNil(loaded.notchDeckID)
    }
}

@MainActor
final class NotchSettingsStoreTests: XCTestCase {
    private var directory: URL!
    private var reloads = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        reloads = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(storage: SettingsStorage(directory: directory), onSaved: { [unowned self] in reloads += 1 })
    }

    func testTheSwitchAndTheDeckChoicePersistAcrossLaunches() {
        let id = UUID()
        let first = makeStore()
        XCTAssertTrue(first.showsNotch)
        XCTAssertNil(first.notchDeckID)

        first.showsNotch = false
        first.notchDeckID = id

        let relaunched = makeStore()
        XCTAssertFalse(relaunched.showsNotch)
        XCTAssertEqual(relaunched.notchDeckID, id)
    }

    func testNotchSettingsDoNotRebuildTheWidgetsButTheAccentDoes() {
        let store = makeStore()
        store.showsNotch = false
        store.notchDeckID = UUID()
        XCTAssertEqual(reloads, 0, "widgets don't depend on the notch")

        store.accent = .blue
        XCTAssertEqual(reloads, 1)
    }

    func testSettingTheSameValueSavesNothing() throws {
        let store = makeStore()
        store.showsNotch = true
        store.notchDeckID = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: SettingsStorage(directory: directory).fileURL.path))
    }

    func testChangingOneSettingKeepsTheOthers() {
        let id = UUID()
        let store = makeStore()
        store.accent = .teal
        store.notchDeckID = id
        store.showsNotch = false

        let loaded = SettingsStorage(directory: directory).load()
        XCTAssertEqual(loaded, AppSettings(accent: .teal, showsNotch: false, notchDeckID: id))
    }
}

@MainActor
final class NotchVisibilityTests: XCTestCase {
    private var root: URL!
    private let far = ScreenMetrics(
        frame: CGRect(x: -70_000, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: -70_000, y: 0, width: 1710, height: 1073.5),
        safeAreaTop: 33.5,
        auxiliaryTopLeft: CGRect(x: -70_000, y: 1073.5, width: 762.5, height: 33.5),
        auxiliaryTopRight: CGRect(x: -70_000 + 947.5, y: 1073.5, width: 762.5, height: 33.5)
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
        var settings: SettingsStore
        var spanish: Deck
        var biology: Deck
    }

    /// Two decks, the far-away display so the panel can really be shown without appearing on screen.
    private func makeRig(preset: AppSettings = AppSettings(), monitors: Bool = true) throws -> Rig {
        let spanish = Deck(name: "Spanish", color: .green, cards: (1...5).map { Card(front: "s\($0)", back: "answer s\($0)") })
        let biology = Deck(name: "Biology", color: .purple, cards: (1...3).map { Card(front: "b\($0)", back: "answer b\($0)") })
        try DeckStorage(directory: root).save([spanish, biology])
        try SettingsStorage(directory: root).save(preset)

        let decks = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let controller = NotchController(
            placementProvider: { [far] in NotchGeometry.placement(for: far) },
            showsPanel: true,
            installsMonitors: monitors,
            expandDelay: .milliseconds(5), collapseDelay: .milliseconds(5), collapseAnimation: .milliseconds(10),
            watchDirectory: root,
            clock: { Date(timeIntervalSince1970: 100) },
            deckStore: { decks }, playbackStore: { playback }, settingsStore: { settings }
        )
        addTeardownBlock { controller.stop() }
        return Rig(controller: controller, decks: decks, playback: playback, settings: settings, spanish: spanish, biology: biology)
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: Default

    func testByDefaultTheNotchIsOnAndShowsTheFirstDeck() throws {
        let rig = try makeRig()
        rig.controller.start()
        XCTAssertTrue(rig.controller.isShowing)
        XCTAssertEqual(rig.controller.panel?.isVisible, true)
        XCTAssertEqual(rig.controller.model.showing?.deckName, "Spanish")
    }

    // MARK: Show in notch

    func testTurningItOffHidesTheNotchAndStopsEverythingItWasListeningTo() throws {
        let rig = try makeRig()
        rig.controller.start()
        XCTAssertTrue(rig.controller.hasPointerMonitors)
        XCTAssertTrue(rig.controller.isListeningForChanges)
        XCTAssertTrue(rig.controller.hasRotationTimer)

        rig.settings.showsNotch = false
        spin { !rig.controller.isShowing }

        XCTAssertFalse(rig.controller.isShowing)
        XCTAssertEqual(rig.controller.panel?.isVisible, false, "hidden at once")
        XCTAssertFalse(rig.controller.hasPointerMonitors, "no mouse monitoring while off")
        XCTAssertFalse(rig.controller.isListeningForChanges, "no folder watching while off")
        XCTAssertFalse(rig.controller.hasRotationTimer, "no timer while off")
    }

    func testTurningItBackOnShowsItAgainWithCurrentContent() throws {
        let rig = try makeRig()
        rig.controller.start()
        rig.settings.showsNotch = false
        spin { !rig.controller.isShowing }

        // The library changes while it is off.
        rig.decks.renameDeck(rig.spanish.id, to: "Español")

        rig.settings.showsNotch = true
        spin { rig.controller.isShowing }

        XCTAssertTrue(rig.controller.isShowing)
        XCTAssertEqual(rig.controller.panel?.isVisible, true)
        XCTAssertTrue(rig.controller.hasPointerMonitors)
        XCTAssertTrue(rig.controller.isListeningForChanges)
        XCTAssertEqual(rig.controller.model.showing?.deckName, "Español", "it picked up what changed meanwhile")
    }

    func testAnOpenNotchIsClosedAndClickThroughWhenHidden() throws {
        let rig = try makeRig()
        rig.controller.start()
        rig.controller.expand()
        XCTAssertTrue(rig.controller.model.isExpanded)

        rig.settings.showsNotch = false
        spin { !rig.controller.isShowing }

        XCTAssertFalse(rig.controller.model.isExpanded)
        XCTAssertFalse(rig.controller.model.showsExpandedContent, "its countdown stops too")
        XCTAssertEqual(rig.controller.panel?.ignoresMouseEvents, true)
    }

    func testItStaysHiddenIfItWasSavedAsOff() throws {
        let rig = try makeRig(preset: AppSettings(showsNotch: false))
        rig.controller.start()
        XCTAssertFalse(rig.controller.isShowing)
        XCTAssertEqual(rig.controller.panel?.isVisible, false)
        XCTAssertFalse(rig.controller.hasPointerMonitors)
        XCTAssertFalse(rig.controller.isListeningForChanges)
    }

    func testHoverDoesNothingWhileOff() throws {
        let rig = try makeRig(preset: AppSettings(showsNotch: false))
        rig.controller.start()
        let frame = try XCTUnwrap(rig.controller.collapsedFrame)
        rig.controller.handlePointer(CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertNil(rig.controller.pendingExpand, "no hover tracking while hidden")
        XCTAssertFalse(rig.controller.model.isExpanded)
    }

    // MARK: Which deck

    func testTheChosenDeckIsShown() throws {
        let rig = try makeRig(preset: AppSettings(notchDeckID: nil))
        rig.controller.start()
        XCTAssertEqual(rig.controller.model.showing?.deckName, "Spanish")

        rig.settings.notchDeckID = rig.biology.id
        spin { rig.controller.model.showing?.deckName == "Biology" }
        XCTAssertEqual(rig.controller.model.showing?.deckName, "Biology")
        XCTAssertEqual(rig.controller.model.showing?.deckColor, .purple)
        XCTAssertEqual(rig.controller.model.showing?.positionText, "1/3")
    }

    func testTheChoiceIsRestoredOnTheNextLaunch() throws {
        let rig = try makeRig()
        rig.settings.notchDeckID = rig.biology.id
        rig.controller.stop()

        // A new launch: fresh settings store and controller over the same saved files.
        let relaunchedSettings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let relaunched = NotchController(
            placementProvider: { [far] in NotchGeometry.placement(for: far) },
            showsPanel: false, installsMonitors: false, watchDirectory: root,
            clock: { Date(timeIntervalSince1970: 100) },
            deckStore: { rig.decks }, playbackStore: { rig.playback }, settingsStore: { relaunchedSettings }
        )
        addTeardownBlock { relaunched.stop() }
        relaunched.start()
        XCTAssertEqual(relaunched.model.showing?.deckName, "Biology")
    }

    func testADeletedChosenDeckFallsBackToTheFirst() throws {
        let rig = try makeRig()
        rig.settings.notchDeckID = rig.biology.id
        rig.controller.start()
        XCTAssertEqual(rig.controller.model.showing?.deckName, "Biology")

        rig.decks.deleteDeck(rig.biology.id)
        spin { rig.controller.model.showing?.deckName == "Spanish" }
        XCTAssertEqual(rig.controller.model.showing?.deckName, "Spanish")
    }

    func testFlipAndSkipActOnTheChosenDeckOnly() throws {
        let rig = try makeRig(preset: AppSettings(notchDeckID: nil))
        rig.settings.notchDeckID = rig.biology.id
        rig.controller.start()

        rig.controller.model.onSkip()
        rig.controller.model.onFlip()

        XCTAssertEqual(rig.playback.state(for: rig.biology.id).skipOffset, 1)
        XCTAssertNotNil(rig.playback.state(for: rig.biology.id).flip)
        XCTAssertEqual(rig.playback.state(for: rig.spanish.id), PlaybackState(), "the other deck is untouched")
    }

    func testRenamingTheChosenDeckUpdatesTheNotch() throws {
        let rig = try makeRig()
        rig.settings.notchDeckID = rig.biology.id
        rig.controller.start()
        rig.decks.renameDeck(rig.biology.id, to: "Life Sciences")
        spin { rig.controller.model.showing?.deckName == "Life Sciences" }
        XCTAssertEqual(rig.controller.model.showing?.deckName, "Life Sciences")
    }
}

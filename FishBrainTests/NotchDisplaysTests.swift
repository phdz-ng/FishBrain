import AppKit
import XCTest

/// Which displays get a notch, for every combination of the settings (FLAS-36).
final class NotchDisplayPolicyTests: XCTestCase {
    private let notchedBuiltIn = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073.5),
        safeAreaTop: 33.5,
        auxiliaryTopLeft: CGRect(x: 0, y: 1073.5, width: 762.5, height: 33.5),
        auxiliaryTopRight: CGRect(x: 947.5, y: 1073.5, width: 762.5, height: 33.5),
        displayID: 1, isBuiltIn: true
    )
    /// An older MacBook: its own display, no notch.
    private let plainBuiltIn = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil,
        displayID: 2, isBuiltIn: true
    )
    private let monitor = ScreenMetrics(
        frame: CGRect(x: 1710, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1710, y: 0, width: 2560, height: 1415),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil,
        displayID: 3, isBuiltIn: false
    )

    private func shown(_ screens: [ScreenMetrics], active: UInt32? = nil, _ options: NotchDisplayOptions = NotchDisplayOptions()) -> Set<UInt32> {
        NotchDisplayPolicy.displaysToShow(screens: screens, activeDisplayID: active, options: options)
    }

    func testTheDefaultsShowOnTheMacsOwnDisplayOnly() {
        XCTAssertEqual(shown([notchedBuiltIn, monitor]), [1])
        XCTAssertEqual(shown([plainBuiltIn, monitor]), [2], "an older MacBook gets the drawn notch with no setting needed")
    }

    func testTheExternalDisplaysSwitchAddsTheMonitors() {
        let on = NotchDisplayOptions(showsOnExternalDisplays: true)
        XCTAssertEqual(shown([notchedBuiltIn, monitor], on), [1, 3])
        XCTAssertEqual(shown([plainBuiltIn, monitor], on), [2, 3])
    }

    func testShowInNotchOffHidesEverything() {
        let off = NotchDisplayOptions(showsNotch: false, showsOnExternalDisplays: true)
        XCTAssertEqual(shown([notchedBuiltIn, monitor], off), [])
    }

    func testAMacWithOnlyMonitorsStillGetsOneOnThePrimary() {
        // A desktop Mac, or a laptop with its lid closed: no display of its own.
        XCTAssertEqual(shown([monitor]), [3])
        var second = monitor
        second.displayID = 4
        XCTAssertEqual(shown([monitor, second]), [3], "only the primary stands in")
        XCTAssertEqual(shown([monitor, second], NotchDisplayOptions(showsOnExternalDisplays: true)), [3, 4])
    }

    func testAHiddenMenuBarHidesTheDrawnNotchByDefault() {
        var fullScreen = plainBuiltIn
        fullScreen.visibleFrame = fullScreen.frame // a full-screen app: no menu bar reserved
        XCTAssertTrue(fullScreen.isMenuBarHidden)
        XCTAssertEqual(shown([fullScreen, monitor]), [])
        XCTAssertEqual(shown([fullScreen]), [])
    }

    func testFullScreenOnOneDisplayLeavesTheOthersAlone() {
        var fullScreen = monitor
        fullScreen.visibleFrame = fullScreen.frame
        XCTAssertEqual(shown([plainBuiltIn, fullScreen], NotchDisplayOptions(showsOnExternalDisplays: true)), [2])
    }

    func testTurningFullScreenHidingOffKeepsItOverFullScreenApps() {
        var fullScreen = plainBuiltIn
        fullScreen.visibleFrame = fullScreen.frame
        XCTAssertEqual(shown([fullScreen], NotchDisplayOptions(hidesInFullScreen: false)), [2])
    }

    func testARealNotchIsNotHiddenByTheMenuBarRule() {
        var fullScreen = notchedBuiltIn
        fullScreen.visibleFrame = fullScreen.frame
        XCTAssertFalse(fullScreen.isMenuBarHidden, "the camera strip is still on screen")
        XCTAssertEqual(shown([fullScreen]), [1])
    }

    func testOnlyTheActiveDisplayWhenAsked() {
        let options = NotchDisplayOptions(showsOnExternalDisplays: true, onlyOnActiveDisplay: true)
        XCTAssertEqual(shown([notchedBuiltIn, monitor], active: 1, options), [1])
        XCTAssertEqual(shown([notchedBuiltIn, monitor], active: 3, options), [3], "it moves with you")
    }

    func testOnlyOnTheActiveDisplayStillRespectsTheExternalSwitch() {
        let options = NotchDisplayOptions(showsOnExternalDisplays: false, onlyOnActiveDisplay: true)
        XCTAssertEqual(shown([notchedBuiltIn, monitor], active: 3, options), [], "the monitor isn't enabled, so nowhere shows")
    }

    func testAnUnknownActiveDisplayDoesNotHideEverything() {
        let options = NotchDisplayOptions(showsOnExternalDisplays: true, onlyOnActiveDisplay: true)
        XCTAssertEqual(shown([notchedBuiltIn, monitor], active: nil, options), [1, 3])
    }

    func testNoDisplaysShowsNothing() {
        XCTAssertEqual(shown([]), [])
    }
}

final class ActiveDisplayTests: XCTestCase {
    private let builtIn = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, displayID: 1, isBuiltIn: true
    )
    /// Above and to the right of the primary in AppKit coordinates (y up).
    private let monitor = ScreenMetrics(
        frame: CGRect(x: 1440, y: 300, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1440, y: 300, width: 2560, height: 1415),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, displayID: 2, isBuiltIn: false
    )

    func testAWindowOnThePrimaryDisplay() {
        // Core Graphics: origin top left of the primary, y down.
        XCTAssertEqual(ActiveDisplay.displayID(forWindowBounds: CGRect(x: 100, y: 100, width: 800, height: 600), screens: [builtIn, monitor]), 1)
    }

    func testAWindowOnTheMonitorAboveTheRightOfThePrimary() {
        // The monitor's top edge is 840 above the primary's top (y 1740 up), so CG y runs negative.
        let bounds = CGRect(x: 2000, y: -500, width: 800, height: 600)
        XCTAssertEqual(ActiveDisplay.displayID(forWindowBounds: bounds, screens: [builtIn, monitor]), 2)
    }

    func testAWindowOffEveryDisplayIsUnknown() {
        XCTAssertNil(ActiveDisplay.displayID(forWindowBounds: CGRect(x: 9000, y: 9000, width: 10, height: 10), screens: [builtIn, monitor]))
        XCTAssertNil(ActiveDisplay.displayID(forWindowBounds: .zero, screens: []))
    }
}

final class DrawnNotchGeometryTests: XCTestCase {
    private let plain = ScreenMetrics(
        frame: CGRect(x: 1710, y: -200, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1710, y: -200, width: 2560, height: 1415), // 25 pt menu bar
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )

    func testTheDrawnPillIsExactlyAsTallAsTheMenuBarAndFlushWithTheTop() {
        let frame = NotchGeometry.placement(for: plain).alignedDrawnFrame(width: 150)
        XCTAssertEqual(frame.height, 25)
        XCTAssertEqual(frame.maxY, plain.frame.maxY)
        XCTAssertEqual(frame.midX, plain.frame.midX, accuracy: 0.5)
    }

    func testAFractionalMenuBarHeightRoundsDownSoItNeverCoversTheTitleBars() {
        var m = plain
        m.visibleFrame = CGRect(x: 1710, y: -200, width: 2560, height: 1440 - 24.5)
        let frame = NotchGeometry.placement(for: m).alignedDrawnFrame(width: 150)
        XCTAssertEqual(frame.height, 24)
        XCTAssertLessThanOrEqual(frame.height, 24.5)
    }

    func testTheDrawnPillIsNarrowAndStaysUnderTheModestLimit() {
        XCTAssertEqual(NotchGeometry.drawnWidth(forPositionText: "12/48"), NotchGeometry.drawnRestWidth)
        XCTAssertLessThan(NotchGeometry.drawnWidth(forPositionText: "1234/5678"), 300)
    }

    func testTheDrawnPillGrowsForLongPositions() {
        XCTAssertGreaterThan(NotchGeometry.drawnWidth(forPositionText: "123/456"), NotchGeometry.drawnWidth(forPositionText: "1/9"))
    }

    func testTheDisplayRulesReadTheScreenMetrics() {
        XCTAssertFalse(plain.hasRealNotch)
        XCTAssertFalse(plain.isMenuBarHidden)
    }
}

final class NotchDisplaySettingsStorageTests: XCTestCase {
    private var directory: URL!
    private var storage: SettingsStorage!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = SettingsStorage(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheDefaults() {
        let settings = AppSettings()
        XCTAssertFalse(settings.showsOnExternalDisplays, "external displays are off until switched on")
        XCTAssertTrue(settings.hidesInFullScreen)
        XCTAssertFalse(settings.onlyOnActiveDisplay)
    }

    func testTheSettingsRoundTrip() throws {
        try storage.save(AppSettings(showsOnExternalDisplays: true, hidesInFullScreen: false, onlyOnActiveDisplay: true))
        let loaded = storage.load()
        XCTAssertTrue(loaded.showsOnExternalDisplays)
        XCTAssertFalse(loaded.hidesInFullScreen)
        XCTAssertTrue(loaded.onlyOnActiveDisplay)
    }

    func testAnOlderFileWithoutTheNewKeysGetsTheDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"accent":"teal","showsNotch":false}"#.utf8).write(to: storage.fileURL)
        let loaded = storage.load()
        XCTAssertEqual(loaded.accent, .teal)
        XCTAssertFalse(loaded.showsNotch, "what was there is kept")
        XCTAssertFalse(loaded.showsOnExternalDisplays)
        XCTAssertTrue(loaded.hidesInFullScreen)
        XCTAssertFalse(loaded.onlyOnActiveDisplay)
    }
}

/// One notch per display that should have one, following displays and settings as they change.
@MainActor
final class NotchDisplayManagerTests: XCTestCase {
    private var root: URL!
    var screens: [ScreenMetrics] = []
    private var active: UInt32?

    func screen(_ id: UInt32, builtIn: Bool = false, notched: Bool = false, menuBarHidden: Bool = false) -> ScreenMetrics {
        let frame = CGRect(x: CGFloat(id) * 3000, y: 0, width: 1710, height: 1107)
        let barHeight: CGFloat = notched ? 33.5 : 24
        return ScreenMetrics(
            frame: frame,
            visibleFrame: CGRect(x: frame.minX, y: 0, width: frame.width, height: frame.height - (menuBarHidden ? 0 : barHeight)),
            safeAreaTop: notched ? 33.5 : 0,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil,
            displayID: id, isBuiltIn: builtIn
        )
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        screens = []
        active = nil
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func makeManager() -> (NotchDisplayManager, SettingsStore) {
        let deckStore = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let manager = NotchDisplayManager(
            screens: { [unowned self] in screens },
            activeDisplay: { [unowned self] _ in active },
            settings: { settings },
            makeController: { [unowned self] id, gate in
                NotchController(
                    placementProvider: { [unowned self] in
                        screens.first { $0.displayID == id }.map(NotchGeometry.placement(for:))
                    },
                    visibilityGate: gate,
                    showsPanel: false, installsMonitors: false,
                    watchDirectory: root,
                    deckStore: { deckStore }, playbackStore: { playback }, settingsStore: { settings }
                )
            }
        )
        addTeardownBlock { manager.stop() }
        return (manager, settings)
    }

    private func shownDisplays(_ manager: NotchDisplayManager) -> Set<UInt32> {
        Set(manager.controllers.filter { $0.value.isShowing }.keys)
    }

    func testAnOlderMacBookGetsADrawnNotchAndTheMonitorDoesNot() {
        screens = [screen(1, builtIn: true), screen(2)]
        let (manager, _) = makeManager()
        manager.start()
        XCTAssertEqual(shownDisplays(manager), [1])
        XCTAssertEqual(manager.controllers[1]?.model.hasCamera, false, "drawn: nothing in the middle")
    }

    func testSwitchingOnExternalDisplaysAddsAndRemovesTheirNotch() async throws {
        screens = [screen(1, builtIn: true), screen(2)]
        let (manager, settings) = makeManager()
        manager.start()
        settings.showsOnExternalDisplays = true
        try await Task.sleep(for: .milliseconds(50)) // the settings change is delivered on the next turn
        XCTAssertEqual(shownDisplays(manager), [1, 2])
        settings.showsOnExternalDisplays = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(shownDisplays(manager), [1], "hidden again, no restart needed")
    }

    func testPluggingAMonitorInAndOut() {
        screens = [screen(1, builtIn: true)]
        let (manager, settings) = makeManager()
        settings.showsOnExternalDisplays = true
        manager.start()
        XCTAssertEqual(shownDisplays(manager), [1])
        screens.append(screen(2))
        manager.reconcile()
        XCTAssertEqual(shownDisplays(manager), [1, 2])
        screens.removeLast()
        manager.reconcile()
        XCTAssertEqual(Set(manager.controllers.keys), [1], "the unplugged display's notch is torn down")
    }

    func testAFullScreenAppHidesItOnThatDisplayAndLeavingBringsItBack() {
        screens = [screen(1, builtIn: true)]
        let (manager, _) = makeManager()
        manager.start()
        XCTAssertEqual(shownDisplays(manager), [1])
        screens = [screen(1, builtIn: true, menuBarHidden: true)]
        manager.reconcile()
        XCTAssertEqual(shownDisplays(manager), [])
        screens = [screen(1, builtIn: true)]
        manager.reconcile()
        XCTAssertEqual(shownDisplays(manager), [1])
    }

    func testTheNotchFollowsTheActiveDisplay() {
        screens = [screen(1, builtIn: true), screen(2)]
        active = 1
        let (manager, settings) = makeManager()
        settings.showsOnExternalDisplays = true
        settings.onlyOnActiveDisplay = true
        manager.start()
        XCTAssertEqual(shownDisplays(manager), [1])
        active = 2
        manager.reconcile()
        XCTAssertEqual(shownDisplays(manager), [2])
    }

    func testShowInNotchOffHidesEveryDisplay() async throws {
        screens = [screen(1, builtIn: true), screen(2)]
        let (manager, settings) = makeManager()
        settings.showsOnExternalDisplays = true
        manager.start()
        XCTAssertEqual(shownDisplays(manager), [1, 2])
        settings.showsNotch = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(shownDisplays(manager), [])
        settings.showsNotch = true
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(shownDisplays(manager), [1, 2])
    }

    func testARealNotchKeepsItsCameraLayout() {
        screens = [screen(1, builtIn: true, notched: true)]
        let (manager, _) = makeManager()
        manager.start()
        XCTAssertEqual(manager.controllers[1]?.model.hasCamera, true)
    }

    func testStopTearsEverythingDown() {
        screens = [screen(1, builtIn: true), screen(2)]
        let (manager, _) = makeManager()
        manager.start()
        manager.stop()
        XCTAssertTrue(manager.controllers.isEmpty)
    }
}

// MARK: - Pill style (FLAS-37)

final class PillStyleTests: XCTestCase {
    func testEveryStyleHasANameAnExplanationAndAnIcon() {
        for style in PillStyle.allCases {
            XCTAssertFalse(style.displayName.isEmpty)
            XCTAssertFalse(style.summary.isEmpty, "people read this before choosing")
            XCTAssertFalse(style.symbolName.isEmpty)
        }
    }

    func testTheExplanationsSayWhatEachOneShows() {
        XCTAssertEqual(PillStyle.classic.displayName, "Classic")
        XCTAssertTrue(PillStyle.classic.summary.contains("camera"), "says it is the real notch's look")
        XCTAssertTrue(PillStyle.fish.summary.contains("fish"))
        XCTAssertTrue(PillStyle.streak.summary.contains("streak"))
        XCTAssertTrue(PillStyle.session.summary.contains("timer"))
    }

    func testClassicIsTheDefaultAndAlwaysAvailable() {
        XCTAssertEqual(AppSettings().pillStyle, .classic)
        XCTAssertTrue(PillStyle.classic.isAvailable)
        XCTAssertEqual(PillStyle.available.first, .classic)
    }

    func testAStyleThatIsNotAvailableYetDrawsAsClassic() {
        for style in PillStyle.allCases where !style.isAvailable {
            XCTAssertEqual(PillStyle.resolved(style), .classic)
        }
        for style in PillStyle.available {
            XCTAssertEqual(PillStyle.resolved(style), style)
        }
    }

    func testAnUnknownStyleFromANewerVersionReadsAsClassic() throws {
        let decoded = try JSONDecoder().decode(PillStyle.self, from: Data(#""aquarium""#.utf8))
        XCTAssertEqual(decoded, .classic)
        XCTAssertEqual(try JSONDecoder().decode(PillStyle.self, from: Data(#""fish""#.utf8)), .fish)
    }

    func testTheChoiceIsSavedAndAnOlderFileGetsClassic() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SettingsStorage(directory: directory)
        try storage.save(AppSettings(pillStyle: .streak))
        XCTAssertEqual(storage.load().pillStyle, .streak)

        try Data(#"{"accent":"teal"}"#.utf8).write(to: storage.fileURL)
        XCTAssertEqual(storage.load().pillStyle, .classic)
    }

    @MainActor
    func testTheStoreSavesAChangeAtOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SettingsStorage(directory: directory)
        let store = SettingsStore(storage: storage, onSaved: {})
        store.pillStyle = .fish
        XCTAssertEqual(storage.load().pillStyle, .fish)
        XCTAssertEqual(SettingsStore(storage: storage, onSaved: {}).pillStyle, .fish, "survives a relaunch")
    }

    @MainActor
    func testTheNoteSaysWhereTheStyleAppliesAndWhenNoDrawnNotchIsOnScreen() {
        var selection = PillStyle.classic
        let withDrawn = PillStylePicker(selection: .init(get: { selection }, set: { selection = $0 }), hasDrawnNotch: true)
        XCTAssertTrue(withDrawn.note.contains("A real notch always shows Classic"))
        XCTAssertFalse(withDrawn.note.contains("applies when one appears"))

        let without = PillStylePicker(selection: .init(get: { selection }, set: { selection = $0 }), hasDrawnNotch: false)
        XCTAssertTrue(without.note.contains("applies when one appears"))
    }
}

extension NotchDisplayManagerTests {
    func testSettingsKnowsWhetherADrawnNotchIsOnScreen() {
        let (manager, _) = makeManager()
        screens = [screen(1, builtIn: true, notched: true)]
        manager.start()
        XCTAssertFalse(manager.hasDrawnNotch, "a real notch isn't drawn")

        screens = [screen(1, builtIn: true, notched: true), screen(2, builtIn: true)]
        manager.reconcile()
        XCTAssertTrue(manager.hasDrawnNotch)

        manager.stop()
        screens = [screen(1, builtIn: true, menuBarHidden: true)]
        manager.start()
        XCTAssertFalse(manager.hasDrawnNotch, "hidden by a full-screen app")
    }

    func testAChosenStyleReachesTheDrawnNotch() async throws {
        screens = [screen(1, builtIn: true)]
        let (manager, settings) = makeManager()
        manager.start()
        settings.pillStyle = .session
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(manager.controllers[1]?.model.pillStyle, .session)
    }
}

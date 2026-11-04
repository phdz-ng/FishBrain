import AppKit
import XCTest

/// FLAS-106: switching the notch's deck from the open notch, and the menu it shares with the sidebar footer.
final class NotchDeckMenuModelTests: XCTestCase {
    private let spanish = Subject(name: "Spanish")
    private lazy var grammar = Subject(name: "Grammar", parentID: spanish.id)

    func testDecksAreGroupedUnderTheirSubjectsWithLooseDecksLast() {
        let verbs = Deck(name: "Verbs", subjectID: grammar.id)
        let words = Deck(name: "Words", subjectID: spanish.id)
        let loose = Deck(name: "Capitals")
        let sections = NotchDeckMenuModel.sections(decks: [loose, verbs, words], subjects: [spanish, grammar])
        XCTAssertEqual(sections, [
            NotchDeckMenuSection(title: "Spanish", decks: [DeckChoice(id: words.id, name: "Words")]),
            NotchDeckMenuSection(title: "Spanish › Grammar", decks: [DeckChoice(id: verbs.id, name: "Verbs")]),
            NotchDeckMenuSection(title: "Decks", decks: [DeckChoice(id: loose.id, name: "Capitals")]),
        ])
    }

    func testWithoutSubjectsTheDecksAreOneUntitledGroupAndEmptyDecksAreListed() {
        let full = Deck(name: "Full", cards: [Card(front: "a", back: "b")])
        let empty = Deck(name: "Empty")
        XCTAssertEqual(NotchDeckMenuModel.sections(decks: [full, empty], subjects: []), [
            NotchDeckMenuSection(title: nil, decks: [DeckChoice(id: full.id, name: "Full"), DeckChoice(id: empty.id, name: "Empty")]),
        ])
        XCTAssertEqual(NotchDeckMenuModel.sections(decks: [], subjects: []), [])
    }

    func testTheFooterSaysAfterThisSessionOnlyWhenTheChoiceDiffersFromTheSessionsDeck() {
        let chosen = Deck(name: "Everyday Spanish")
        XCTAssertEqual(NotchDeckMenuModel.footerLabel(chosen: chosen, sessionDeckID: nil), "Everyday Spanish")
        XCTAssertEqual(NotchDeckMenuModel.footerLabel(chosen: chosen, sessionDeckID: chosen.id), "Everyday Spanish")
        XCTAssertEqual(NotchDeckMenuModel.footerLabel(chosen: chosen, sessionDeckID: UUID()), "After this session: Everyday Spanish")
        XCTAssertEqual(NotchDeckMenuModel.footerLabel(chosen: nil, sessionDeckID: nil), "No decks")
    }

    func testAccessibilityText() {
        XCTAssertEqual(NotchDeckMenuModel.accessibilityLabel, "Notch deck")
        XCTAssertEqual(NotchDeckMenuModel.hint, "Choose which deck the notch shows")
        XCTAssertEqual(NotchDeckMenuModel.lockedHint, "End the session to switch decks")
    }
}

@MainActor
final class NotchDeckMenuControllerTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_030)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Rig {
        var controller: NotchController
        var settings: SettingsStore
        var sessions: SessionStore
        var decks: DeckStore
        var model: NotchModel { controller.model }
    }

    private let subject = Subject(name: "Spanish")
    private lazy var first = Deck(name: "Words", color: .green, cards: (1...5).map { Card(front: "w\($0)", back: "b") }, subjectID: subject.id)
    private lazy var second = Deck(name: "Verbs", color: .purple, cards: (1...5).map { Card(front: "v\($0)", back: "b") })
    private let empty = Deck(name: "Empty", color: .orange)

    private func makeRig() throws -> Rig {
        try DeckStorage(directory: root).save(Library(subjects: [subject], decks: [first, second, empty]))
        let deckStore = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let sessions = SessionStore(storage: SessionStorage(directory: root), studyStorage: StudyStorage(directory: root))
        let screen = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876),
            safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, displayID: 1, isBuiltIn: true
        )
        let controller = NotchController(
            placementProvider: { NotchGeometry.placement(for: screen) },
            showsPanel: false, installsMonitors: false, watchDirectory: root,
            clock: { [now] in now },
            deckStore: { deckStore }, playbackStore: { playback }, settingsStore: { settings },
            studyStore: { StudyStore(storage: StudyStorage(directory: self.root)) }, sessionStore: { sessions }
        )
        addTeardownBlock { controller.stop() }
        controller.start()
        return Rig(controller: controller, settings: settings, sessions: sessions, decks: deckStore)
    }

    func testChoosingADeckFromTheNotchSetsTheNotchDeckAndShowsItsCardAtOnce() throws {
        let rig = try makeRig()
        rig.controller.expand()
        XCTAssertEqual(rig.model.showing?.deckName, "Words")
        XCTAssertEqual(rig.model.shownDeck?.id, first.id)

        rig.model.onChooseDeck(second.id)

        XCTAssertEqual(rig.settings.notchDeckID, second.id)
        XCTAssertEqual(rig.model.showing?.deckName, "Verbs")
        XCTAssertEqual(rig.model.showing?.card.front.hasPrefix("v"), true)
        XCTAssertEqual(rig.model.shownDeck, DeckChoice(id: second.id, name: "Verbs"), "the checkmark moves")
        XCTAssertTrue(rig.model.isExpanded, "the notch stays open")
    }

    func testTheNotchMenuListsTheSameSectionsAsTheSidebarFooter() throws {
        let rig = try makeRig()
        let footer = NotchDeckMenuModel.sections(decks: rig.decks.decks, subjects: rig.decks.subjects)
        XCTAssertEqual(rig.model.deckMenu, footer)
        XCTAssertEqual(rig.model.deckMenu.map(\.title), ["Spanish", "Decks"])
        XCTAssertEqual(rig.model.deckMenu.last?.decks.map(\.name), ["Verbs", "Empty"], "empty decks are listed too")
    }

    func testChoosingAnEmptyDeckShowsTheEmptyStateAndKeepsTheMenu() throws {
        let rig = try makeRig()
        rig.model.onChooseDeck(empty.id)
        XCTAssertNil(rig.model.showing)
        XCTAssertEqual(rig.model.shownDeck, DeckChoice(id: empty.id, name: "Empty"))
        XCTAssertEqual(rig.model.emptyDeckColor, .orange)

        rig.model.onChooseDeck(first.id)
        XCTAssertEqual(rig.model.showing?.deckName, "Words", "and another deck is one click away")
    }

    func testTheMenuIsLockedWhileANotchSessionRuns() throws {
        let rig = try makeRig()
        XCTAssertFalse(rig.model.isDeckLocked)
        rig.model.onStartSession(5)
        XCTAssertNotNil(rig.sessions.active)
        XCTAssertTrue(rig.model.isDeckLocked)

        rig.model.onChooseDeck(second.id)
        XCTAssertNil(rig.settings.notchDeckID, "the session decides the deck until it ends")
        XCTAssertEqual(rig.model.showing?.deckName, "Words")

        rig.model.onEndSession()
        XCTAssertFalse(rig.model.isDeckLocked)
    }

    func testTheSessionKeepsItsDeckWhenTheFooterChoosesAnother() throws {
        let rig = try makeRig()
        rig.model.onStartSession(5)
        // The sidebar footer stays usable during a session; the notch switches once it ends.
        rig.settings.notchDeckID = second.id
        rig.controller.refreshContent()
        XCTAssertEqual(rig.model.showing?.deckName, "Words")
        let gate = StudyClockGate(sessions: rig.sessions)
        XCTAssertEqual(gate.sessionDeckID, first.id)
        let chosen = DeckSelection.resolve(rig.settings.notchDeckID, in: rig.decks.decks)
        XCTAssertEqual(NotchDeckMenuModel.footerLabel(chosen: chosen, sessionDeckID: gate.sessionDeckID), "After this session: Verbs")

        rig.model.onEndSession()
        XCTAssertEqual(rig.model.showing?.deckName, "Verbs")
        XCTAssertNil(gate.sessionDeckID)
    }

    func testAnOpenMenuKeepsTheNotchOpenWhereverThePointerGoes() throws {
        let rig = try makeRig()
        rig.controller.expand()
        let far = CGPoint(x: 10, y: 10)

        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        XCTAssertTrue(rig.controller.isMenuTracking)
        rig.controller.handlePointer(far)
        XCTAssertNil(rig.controller.pendingCollapse)

        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        XCTAssertFalse(rig.controller.isMenuTracking)
        rig.controller.handlePointer(far)
        XCTAssertNotNil(rig.controller.pendingCollapse, "once the menu closes, hovering works as before")
    }
}

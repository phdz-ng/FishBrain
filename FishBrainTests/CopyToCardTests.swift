import AppKit
import XCTest

/// Copy to card (FLAS-43).
final class CopyCandidateTests: XCTestCase {
    func testAWordOrShortPhraseIsACandidateAndIsTrimmed() {
        XCTAssertEqual(CopyCandidate.text(from: "sobremesa"), "sobremesa")
        XCTAssertEqual(CopyCandidate.text(from: "  sin embargo \n"), "sin embargo", "a trailing newline is just trimmed")
        XCTAssertEqual(CopyCandidate.text(from: "tener prisa de verdad hoy"), "tener prisa de verdad hoy", "five words")
        XCTAssertEqual(CopyCandidate.text(from: "résumé naïve"), "résumé naïve")
        XCTAssertEqual(CopyCandidate.text(from: "你好"), "你好")
    }

    func testMoreThanFiveWordsIsNot() {
        XCTAssertNil(CopyCandidate.text(from: "one two three four five six"))
        XCTAssertEqual(CopyCandidate.maxWords, 5)
    }

    func testMoreThanSixtyCharactersIsNot() {
        let sixty = String(repeating: "a", count: 60)
        XCTAssertEqual(CopyCandidate.text(from: sixty), sixty)
        XCTAssertNil(CopyCandidate.text(from: sixty + "a"))
        XCTAssertEqual(CopyCandidate.maxCharacters, 60)
    }

    func testSeveralLinesAreNot() {
        XCTAssertNil(CopyCandidate.text(from: "one\ntwo"))
        XCTAssertNil(CopyCandidate.text(from: "one\r\ntwo"))
    }

    func testNothingIsNot() {
        XCTAssertNil(CopyCandidate.text(from: nil))
        XCTAssertNil(CopyCandidate.text(from: ""))
        XCTAssertNil(CopyCandidate.text(from: "  \n\t "))
    }

    func testTheEditorPrefillKeepsTheFirstLineUpToThreeHundredCharacters() {
        XCTAssertEqual(CopyCandidate.prefill(from: "first line\nsecond line"), "first line")
        XCTAssertEqual(CopyCandidate.prefill(from: nil), "")
        XCTAssertEqual(CopyCandidate.prefill(from: "\n\n  hello  \nworld"), "hello")
        XCTAssertEqual(CopyCandidate.prefill(from: String(repeating: "x", count: 900)).count, 300)
    }

    func testSecretAndShortLivedCopiesAreRecognized() {
        XCTAssertTrue(CopyCandidate.isConcealed(typeIdentifiers: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(CopyCandidate.isConcealed(typeIdentifiers: ["org.nspasteboard.TransientType"]))
        XCTAssertFalse(CopyCandidate.isConcealed(typeIdentifiers: ["public.utf8-plain-text"]))
    }

    func testOnlyTextCopiesCount() {
        XCTAssertTrue(CopyCandidate.hasText(typeIdentifiers: ["public.utf8-plain-text"]))
        XCTAssertTrue(CopyCandidate.hasText(typeIdentifiers: ["public.png", "NSStringPboardType"]))
        XCTAssertFalse(CopyCandidate.hasText(typeIdentifiers: ["public.png", "public.tiff"]))
        XCTAssertFalse(CopyCandidate.hasText(typeIdentifiers: []))
    }
}

final class CopyOfferTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheSameTextCopiedAgainSoonGetsNoSecondOffer() {
        var tracker = CopyOfferTracker()
        XCTAssertTrue(tracker.shouldOffer("hola", at: t0))
        XCTAssertFalse(tracker.shouldOffer("hola", at: t0.addingTimeInterval(2)))
        XCTAssertFalse(tracker.shouldOffer("hola", at: t0.addingTimeInterval(CopyOfferTracker.window - 0.1)))
    }

    func testItIsOfferedAgainOnceTheWindowHasPassed() {
        var tracker = CopyOfferTracker()
        XCTAssertTrue(tracker.shouldOffer("hola", at: t0))
        XCTAssertTrue(tracker.shouldOffer("hola", at: t0.addingTimeInterval(CopyOfferTracker.window)))
    }

    func testDifferentTextIsAlwaysOffered() {
        var tracker = CopyOfferTracker()
        XCTAssertTrue(tracker.shouldOffer("hola", at: t0))
        XCTAssertTrue(tracker.shouldOffer("adiós", at: t0.addingTimeInterval(1)))
        XCTAssertTrue(tracker.shouldOffer("hola", at: t0.addingTimeInterval(2)), "not the last text any more")
    }
}

@MainActor
final class CopyOfferStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnOfferShowsForSixSecondsThenGoesAway() {
        let store = CopyOfferStore()
        store.offer(text: "sin embargo", at: t0)
        XCTAssertEqual(store.banner?.kind, .offer(text: "sin embargo"))
        XCTAssertEqual(store.banner?.expiresAt, t0.addingTimeInterval(6))
        store.expireIfNeeded(at: t0.addingTimeInterval(5.9))
        XCTAssertNotNil(store.banner)
        store.expireIfNeeded(at: t0.addingTimeInterval(6))
        XCTAssertNil(store.banner)
    }

    func testAddedIsShownBriefly() {
        let store = CopyOfferStore()
        store.showAdded(deckName: "Spanish A2", at: t0)
        XCTAssertEqual(store.banner?.kind, .added(deckName: "Spanish A2"))
        store.expireIfNeeded(at: t0.addingTimeInterval(CopyBanner.addedDuration))
        XCTAssertNil(store.banner)
    }

    func testTheWordsOnTheOffer() {
        XCTAssertEqual(CopyBanner(kind: .offer(text: "sin embargo"), expiresAt: t0).offerLabel, "Copied “sin embargo”")
        XCTAssertEqual(CopyBanner(kind: .offer(text: nil), expiresAt: t0).offerLabel, "Copied text")
        XCTAssertTrue(CopyBanner(kind: .offer(text: "hola"), expiresAt: t0).announcement.contains("Control Option C"))
        XCTAssertEqual(CopyBanner(kind: .added(deckName: "Spanish A2"), expiresAt: t0).announcement, "Added to Spanish A2")
        XCTAssertTrue(CopyBanner(kind: .offer(text: nil), expiresAt: t0).isOffer)
        XCTAssertFalse(CopyBanner(kind: .added(deckName: "x"), expiresAt: t0).isOffer)
    }

    func testDismissClearsIt() {
        let store = CopyOfferStore()
        store.offer(text: "x", at: t0)
        store.dismiss()
        XCTAssertNil(store.banner)
    }
}

final class CopySettingTests: XCTestCase {
    func testItIsOffByDefaultBecauseItLooksAtWhatYouCopy() throws {
        XCTAssertFalse(AppSettings().offersCardFromCopy)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SettingsStorage(directory: directory)
        XCTAssertFalse(storage.load().offersCardFromCopy)
        try storage.save(AppSettings(offersCardFromCopy: true))
        XCTAssertTrue(storage.load().offersCardFromCopy)
        try Data(#"{"accent":"teal"}"#.utf8).write(to: storage.fileURL)
        XCTAssertFalse(storage.load().offersCardFromCopy, "an older file")
    }
}

// MARK: - The service

@MainActor
private final class FakePasteboard: PasteboardSource {
    var changeCount = 1
    var typeIdentifiers = ["public.utf8-plain-text"]
    var canReadWithoutPrompt = true
    var text: String?
    private(set) var reads = 0

    func string() -> String? {
        reads += 1
        return text
    }

    /// Someone copies something.
    func copy(_ text: String?, types: [String] = ["public.utf8-plain-text"]) {
        self.text = text
        typeIdentifiers = types
        changeCount += 1
    }
}

@MainActor
private final class FakeHotKey: HotKeyRegistering {
    private(set) var handler: (@MainActor () -> Void)?
    private(set) var registerCount = 0

    func register(_ handler: @escaping @MainActor () -> Void) -> Bool {
        registerCount += 1
        self.handler = handler
        return true
    }

    func unregister() { handler = nil }
}

@MainActor
final class CopyToCardServiceTests: XCTestCase {
    private var root: URL!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var ownAppActive = false
    private var opened: [String] = []

    override func setUpWithError() throws {
        root = try PictureFixtures.tempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Rig {
        var service: CopyToCardService
        var pasteboard: FakePasteboard
        var store: CopyOfferStore
        var hotKey: FakeHotKey
        var settings: SettingsStore
    }

    private func makeRig(enabled: Bool = true) -> Rig {
        let pasteboard = FakePasteboard()
        let store = CopyOfferStore()
        let hotKey = FakeHotKey()
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let service = CopyToCardService(
            pasteboard: pasteboard, store: { store }, settings: { settings }, clock: { self.now },
            isOwnAppActive: { self.ownAppActive }, openEditor: { self.opened.append($0) }, hotKey: hotKey
        )
        if enabled { service.apply(enabled: true) }
        addTeardownBlock { service.stop() }
        return Rig(service: service, pasteboard: pasteboard, store: store, hotKey: hotKey, settings: settings)
    }

    // MARK: Which copies get an offer

    func testAShortCopyInAnotherAppGetsAnOffer() {
        let rig = makeRig()
        rig.pasteboard.copy("sin embargo")
        rig.service.tick()
        XCTAssertEqual(rig.store.banner?.kind, .offer(text: "sin embargo"))
    }

    func testWhatWasAlreadyOnTheClipboardWhenTheSettingWasTurnedOnIsLeftAlone() {
        let rig = makeRig(enabled: false)
        rig.pasteboard.copy("old copy")
        rig.service.apply(enabled: true)
        rig.service.tick()
        XCTAssertNil(rig.store.banner)
        XCTAssertEqual(rig.pasteboard.reads, 0, "not even read")
    }

    func testLongOrMultiLineCopiesGetNoOffer() {
        let rig = makeRig()
        for text in ["one two three four five six", String(repeating: "a", count: 61), "line one\nline two", "   "] {
            rig.pasteboard.copy(text)
            rig.service.tick()
            XCTAssertNil(rig.store.banner, text)
        }
    }

    func testSecretAndShortLivedCopiesAreNeverOfferedOrRead() {
        let rig = makeRig()
        rig.pasteboard.copy("hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        rig.service.tick()
        rig.pasteboard.copy("123456", types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"])
        rig.service.tick()
        XCTAssertNil(rig.store.banner)
        XCTAssertEqual(rig.pasteboard.reads, 0, "a concealed copy is never read")
    }

    func testCopiesMadeInsideFishBrainAreIgnored() {
        let rig = makeRig()
        ownAppActive = true
        rig.pasteboard.copy("la mariposa")
        rig.service.tick()
        XCTAssertNil(rig.store.banner)
        XCTAssertEqual(rig.pasteboard.reads, 0)
    }

    func testACopiedPictureIsNotText() {
        let rig = makeRig()
        rig.pasteboard.copy(nil, types: ["public.png", "public.tiff"])
        rig.service.tick()
        XCTAssertNil(rig.store.banner)
    }

    func testTheSameTextCopiedAgainSoonGetsNoSecondOfferButLaterDoes() {
        let rig = makeRig()
        rig.pasteboard.copy("hola")
        rig.service.tick()
        rig.store.dismiss()
        now = now.addingTimeInterval(3)
        rig.pasteboard.copy("hola")
        rig.service.tick()
        XCTAssertNil(rig.store.banner, "copied again a few seconds later")
        now = now.addingTimeInterval(CopyOfferTracker.window)
        rig.pasteboard.copy("hola")
        rig.service.tick()
        XCTAssertNotNil(rig.store.banner)
    }

    func testNothingNewMeansNoNewLookAtTheClipboard() {
        let rig = makeRig()
        rig.pasteboard.copy("hola")
        rig.service.tick()
        let reads = rig.pasteboard.reads
        rig.store.dismiss()
        rig.service.tick()
        rig.service.tick()
        XCTAssertEqual(rig.pasteboard.reads, reads, "the change count didn't move, so it isn't read again")
        XCTAssertNil(rig.store.banner)
    }

    // MARK: The clipboard permission

    func testWhenMacOSWouldAskTheOfferIsMadeWithoutReadingWhatWasCopied() {
        let rig = makeRig()
        rig.pasteboard.canReadWithoutPrompt = false
        rig.pasteboard.copy("sin embargo")
        rig.service.tick()
        XCTAssertEqual(rig.store.banner?.kind, .offer(text: nil))
        XCTAssertEqual(rig.pasteboard.reads, 0, "nothing was read, so macOS had nothing to ask about")
        XCTAssertEqual(rig.store.banner?.offerLabel, "Copied text")
    }

    func testEvenWithoutReadingASecretCopyGetsNoOffer() {
        let rig = makeRig()
        rig.pasteboard.canReadWithoutPrompt = false
        rig.pasteboard.copy("hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        rig.service.tick()
        XCTAssertNil(rig.store.banner)
    }

    // MARK: Turning it on and off

    func testItDoesNothingWhileTheSettingIsOff() {
        let rig = makeRig(enabled: false)
        XCTAssertFalse(rig.service.isRunning)
        rig.pasteboard.copy("hola")
        rig.service.tick()
        XCTAssertNil(rig.store.banner)
        XCTAssertEqual(rig.hotKey.registerCount, 0, "no shortcut either")
    }

    func testTurningItOnRegistersTheShortcutAndOffUndoesEverything() {
        let rig = makeRig()
        XCTAssertEqual(rig.hotKey.registerCount, 1)
        XCTAssertNotNil(rig.hotKey.handler)
        rig.pasteboard.copy("hola")
        rig.service.tick()
        XCTAssertNotNil(rig.store.banner)
        rig.service.apply(enabled: false)
        XCTAssertNil(rig.hotKey.handler)
        XCTAssertNil(rig.store.banner, "an offer still showing goes away")
        rig.pasteboard.copy("adiós")
        rig.service.tick()
        XCTAssertNil(rig.store.banner)
    }

    func testItFollowsTheSettingWithoutARestart() async throws {
        let rig = makeRig(enabled: false)
        rig.service.start()
        XCTAssertFalse(rig.service.isRunning)
        rig.settings.offersCardFromCopy = true
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(rig.service.isRunning)
        rig.settings.offersCardFromCopy = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(rig.service.isRunning)
    }

    func testTheLookIsOncePerSecondAtMostAndMayDrift() {
        XCTAssertGreaterThanOrEqual(CopyToCardService.pollInterval, 1)
        XCTAssertGreaterThan(CopyToCardService.pollTolerance, 0)
    }

    // MARK: The shortcut

    func testTheShortcutOpensTheEditorOnWhatIsOnTheClipboard() {
        let rig = makeRig()
        rig.pasteboard.text = "  la sobremesa  \nsecond line"
        rig.hotKey.handler?()
        XCTAssertEqual(opened, ["la sobremesa"], "the first line, trimmed")
    }

    func testTheShortcutWithNothingCopiedOpensAnEmptyEditor() {
        let rig = makeRig()
        rig.pasteboard.text = nil
        rig.hotKey.handler?()
        XCTAssertEqual(opened, [""])
    }
}

// MARK: - The notch

@MainActor
final class CopyToCardNotchTests: XCTestCase {
    private var root: URL!
    private var now = Date(timeIntervalSince1970: 1_800_000_030)
    private var clipboard: String?
    private var saves = 0

    override func setUpWithError() throws {
        root = try PictureFixtures.tempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Rig {
        var controller: NotchController
        var decks: DeckStore
        var copy: CopyOfferStore
        var spanish: Deck
        var biology: Deck
    }

    private func makeRig(drawn: Bool = true) throws -> Rig {
        let spanish = Deck(name: "Spanish A2", color: .green, cards: (1...3).map { Card(front: "f\($0)", back: "b\($0)") })
        let biology = Deck(name: "Biology", color: .purple, cards: [Card(front: "mitosis", back: "cell division")])
        try DeckStorage(directory: root).save([spanish, biology])
        let decks = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(1), onSaved: { [unowned self] in saves += 1 })
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let copy = CopyOfferStore()
        let screen = drawn
            ? ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876),
                            safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, displayID: 1, isBuiltIn: true)
            : ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1710, height: 1107), visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073.5),
                            safeAreaTop: 33.5, auxiliaryTopLeft: CGRect(x: 0, y: 1073.5, width: 762.5, height: 33.5),
                            auxiliaryTopRight: CGRect(x: 947.5, y: 1073.5, width: 762.5, height: 33.5), displayID: 1, isBuiltIn: true)
        let controller = NotchController(
            placementProvider: { NotchGeometry.placement(for: screen) },
            showsPanel: false, installsMonitors: false, expandDelay: .milliseconds(1), collapseDelay: .milliseconds(1),
            collapseAnimation: .milliseconds(1), watchDirectory: root, clock: { self.now },
            deckStore: { decks }, playbackStore: { playback }, settingsStore: { settings },
            copyStore: { copy }, clipboardText: { self.clipboard }
        )
        addTeardownBlock { controller.stop() }
        controller.start()
        return Rig(controller: controller, decks: decks, copy: copy, spanish: spanish, biology: biology)
    }

    // MARK: The offer

    func testAnOfferTakesOverTheDrawnPillAndItsWidth() throws {
        let rig = try makeRig()
        let before = try XCTUnwrap(rig.controller.collapsedFrame).width
        rig.copy.offer(text: "sin embargo", at: now)
        rig.controller.refreshContent()
        XCTAssertEqual(rig.controller.model.banner?.kind, .offer(text: "sin embargo"))
        XCTAssertEqual(try XCTUnwrap(rig.controller.collapsedFrame).width, NotchGeometry.bannerRestWidth)
        XCTAssertNotEqual(before, NotchGeometry.bannerRestWidth)
        XCTAssertLessThanOrEqual(NotchGeometry.bannerRestWidth, 300)
    }

    func testOnARealNotchTheOfferIsAChipBesideTheCamera() throws {
        let rig = try makeRig(drawn: false)
        let before = try XCTUnwrap(rig.controller.collapsedFrame).width
        rig.copy.offer(text: "sin embargo", at: now)
        rig.controller.refreshContent()
        let after = try XCTUnwrap(rig.controller.collapsedFrame).width
        XCTAssertGreaterThanOrEqual(after, before, "room for '+ Card'")
        XCTAssertEqual(rig.controller.model.hasCamera, true)
    }

    func testTheOfferGoesAwayOnItsOwnAfterSixSeconds() throws {
        let rig = try makeRig()
        rig.copy.offer(text: "hola", at: now)
        rig.controller.refreshContent()
        XCTAssertNotNil(rig.controller.model.banner)
        now = now.addingTimeInterval(7)
        rig.controller.refreshContent()
        XCTAssertNil(rig.controller.model.banner)
        XCTAssertEqual(rig.controller.collapsedFrame?.width, NotchGeometry.drawnWidth(forPositionText: rig.controller.model.showing?.positionText, style: rig.controller.model.restStyle))
    }

    func testTheNotchTakesClicksOnlyWhileAnOfferShows() throws {
        let rig = try makeRig()
        let panel = try XCTUnwrap(rig.controller.panel)
        XCTAssertTrue(panel.ignoresMouseEvents, "at rest, clicks go through")
        rig.copy.offer(text: "hola", at: now)
        rig.controller.refreshContent()
        XCTAssertFalse(panel.ignoresMouseEvents, "the offer is a button")
        now = now.addingTimeInterval(7)
        rig.controller.refreshContent()
        XCTAssertTrue(panel.ignoresMouseEvents, "and back")
    }

    func testHoveringTheOfferDoesNotOpenTheStudyCardOverIt() async throws {
        let rig = try makeRig()
        rig.copy.offer(text: "hola", at: now)
        rig.controller.refreshContent()
        let frame = try XCTUnwrap(rig.controller.collapsedFrame)
        rig.controller.handlePointer(CGPoint(x: frame.midX, y: frame.midY))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(rig.controller.model.isExpanded)
    }

    // MARK: The editor

    func testClickingTheOfferOpensTheEditorOnTheCopiedTextInTheNotchsDeck() throws {
        let rig = try makeRig()
        rig.copy.offer(text: "sin embargo", at: now)
        rig.controller.refreshContent()
        rig.controller.model.onAcceptOffer()
        XCTAssertEqual(rig.controller.model.cardDraft, CardDraft(front: "sin embargo", back: "", deckID: rig.spanish.id))
        XCTAssertTrue(rig.controller.model.isExpanded, "the notch opens")
        XCTAssertNil(rig.copy.banner, "the offer is used up")
    }

    func testAnOfferMadeWithoutReadingReadsTheTextNow() throws {
        let rig = try makeRig()
        clipboard = "una frase\nsecond line"
        rig.copy.offer(text: nil, at: now)
        rig.controller.refreshContent()
        rig.controller.model.onAcceptOffer()
        XCTAssertEqual(rig.controller.model.cardDraft?.front, "una frase", "read when clicked, first line")
    }

    func testSavingAddsTheCardToTheEndOfTheDeckAndSaysSo() async throws {
        let rig = try makeRig()
        rig.controller.beginCardDraft(front: "sin embargo")
        rig.controller.model.cardDraft?.back = "however"
        rig.controller.model.onSaveDraft()
        let cards = try XCTUnwrap(rig.decks.decks.first { $0.id == rig.spanish.id }).cards
        XCTAssertEqual(cards.count, 4)
        XCTAssertEqual(cards.last?.front, "sin embargo")
        XCTAssertEqual(cards.last?.back, "however")
        XCTAssertNil(rig.controller.model.cardDraft, "the editor closes")
        XCTAssertEqual(rig.controller.model.banner?.kind, .added(deckName: "Spanish A2"))
        XCTAssertEqual(rig.controller.model.banner?.announcement, "Added to Spanish A2")
        await rig.decks.pendingSave?.value
        XCTAssertGreaterThan(saves, 0, "saved like any edit, which also refreshes the widgets")
    }

    func testTheDeckMenuChoosesWhereTheCardGoes() throws {
        let rig = try makeRig()
        rig.controller.beginCardDraft(front: "ribosome")
        XCTAssertEqual(rig.controller.model.deckChoices.map(\.name), ["Spanish A2", "Biology"])
        rig.controller.model.cardDraft?.deckID = rig.biology.id
        rig.controller.model.onSaveDraft()
        XCTAssertEqual(rig.decks.decks.first { $0.id == rig.biology.id }?.cards.last?.front, "ribosome")
        XCTAssertEqual(rig.decks.decks.first { $0.id == rig.spanish.id }?.cards.count, 3, "the other deck is untouched")
        XCTAssertEqual(rig.controller.model.banner?.kind, .added(deckName: "Biology"))
    }

    func testCancelClosesWithoutAddingAnything() throws {
        let rig = try makeRig()
        rig.controller.beginCardDraft(front: "sin embargo")
        rig.controller.model.onCancelDraft()
        XCTAssertNil(rig.controller.model.cardDraft)
        XCTAssertEqual(rig.decks.decks.map { $0.cards.count }, [3, 1])
        XCTAssertNil(rig.controller.model.banner)
    }

    func testAnEmptyFrontCannotBeSaved() throws {
        let rig = try makeRig()
        rig.controller.beginCardDraft(front: "")
        rig.controller.model.onSaveDraft()
        XCTAssertNotNil(rig.controller.model.cardDraft, "still open")
        XCTAssertEqual(rig.decks.decks.map { $0.cards.count }, [3, 1])
        rig.controller.model.cardDraft?.front = "   "
        rig.controller.model.onSaveDraft()
        XCTAssertEqual(rig.decks.decks.map { $0.cards.count }, [3, 1])
    }

    func testTheNotchStaysOpenWhileACardIsBeingWritten() async throws {
        let rig = try makeRig()
        rig.controller.beginCardDraft(front: "hola")
        rig.controller.handlePointer(CGPoint(x: -5000, y: -5000)) // the pointer wandered far away
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(rig.controller.model.isExpanded)
        XCTAssertNotNil(rig.controller.model.cardDraft)
    }

    func testWithNoDeckNothingOpens() throws {
        let rig = try makeRig()
        for deck in rig.decks.decks { rig.decks.deleteDeck(deck.id) }
        rig.controller.beginCardDraft(front: "hola")
        XCTAssertNil(rig.controller.model.cardDraft)
    }

    func testTheEditorNeedsTheKeyboardOnlyWhileItIsOpen() throws {
        let rig = try makeRig()
        let panel = try XCTUnwrap(rig.controller.panel)
        XCTAssertFalse(panel.canBecomeKey, "never, by default")
        rig.controller.beginCardDraft(front: "hola")
        rig.controller.model.onCancelDraft()
        XCTAssertFalse(panel.canBecomeKey, "and given back")
    }

    func testTwoDisplaysShareTheOffer() throws {
        let rig = try makeRig()
        let second = NotchController(
            placementProvider: { nil }, showsPanel: false, installsMonitors: false, watchDirectory: root, clock: { self.now },
            deckStore: { rig.decks }, playbackStore: { PlaybackStore(storage: PlaybackStorage(directory: self.root), onSaved: {}) },
            settingsStore: { SettingsStore(storage: SettingsStorage(directory: self.root), onSaved: {}) },
            copyStore: { rig.copy }
        )
        addTeardownBlock { second.stop() }
        second.start()
        rig.copy.offer(text: "hola", at: now)
        rig.controller.refreshContent()
        second.refreshContent()
        XCTAssertEqual(second.model.banner, rig.controller.model.banner)
    }

    func testWithoutAnOfferStoreNothingChanges() throws {
        let decks = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(1), onSaved: {})
        let controller = NotchController(
            placementProvider: { nil }, showsPanel: false, installsMonitors: false, watchDirectory: root,
            deckStore: { decks },
            playbackStore: { PlaybackStore(storage: PlaybackStorage(directory: self.root), onSaved: {}) },
            settingsStore: { SettingsStore(storage: SettingsStorage(directory: self.root), onSaved: {}) }
        )
        addTeardownBlock { controller.stop() }
        controller.start()
        XCTAssertNil(controller.model.banner)
        controller.model.onAcceptOffer()
        XCTAssertNil(controller.model.cardDraft)
    }
}

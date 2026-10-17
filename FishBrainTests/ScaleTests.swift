import SwiftUI
import XCTest

/// Large decks and long text. The budgets are generous (a slow CI machine passes) but would catch
/// anything that turns quadratic.
@MainActor
final class ScaleTests: XCTestCase {
    private func bigDeck(cards: Int, textLength: Int = 40) -> Deck {
        let filler = String(repeating: "palabra ", count: textLength / 8 + 1).prefix(textLength)
        return Deck(
            name: "Big",
            color: .accent,
            cards: (0..<cards).map { Card(front: "Front \($0) \(filler)", back: "Back \($0) \(filler)") }
        )
    }

    private func seconds(_ work: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        let elapsed = try clock.measure(work)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    func testFiveThousandCardsSaveAndLoadQuickly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = DeckStorage(directory: directory)
        let decks = [bigDeck(cards: 5_000)]

        XCTAssertLessThan(try seconds { try storage.save(decks) }, 2)
        var loaded: [Deck] = []
        XCTAssertLessThan(seconds { loaded = storage.load() }, 2)
        XCTAssertEqual(loaded.first?.cards.count, 5_000)
    }

    func testSearchingFiveThousandCardsIsFast() {
        let decks = [bigDeck(cards: 5_000), bigDeck(cards: 5_000)]
        var count = 0
        XCTAssertLessThan(seconds { count = CardSearch.search("front 4999", in: decks).count }, 1)
        XCTAssertEqual(count, 2)
    }

    func testPickingTheCurrentCardInALargeDeckIsInstant() {
        let deck = bigDeck(cards: 10_000)
        let now = Date()
        let elapsed = seconds {
            for offset in 0..<288 { // a day of rotations
                _ = NowShowing.make(deck: deck, state: PlaybackState(), at: now.addingTimeInterval(Double(offset) * 300))
            }
        }
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testParsingAThousandLinePasteIsFast() {
        let text = (0..<5_000).map { "word \($0), palabra \($0)" }.joined(separator: "\n")
        var result: CardParseResult?
        XCTAssertLessThan(seconds { result = CardParser.parse(text) }, 1)
        XCTAssertEqual(result?.cards.count, 5_000)
    }

    func testAVeryLongCardRendersWithoutStalling() {
        let long = String(repeating: "A very long sentence that keeps going. ", count: 1_000) // ~39,000 characters
        for size in [CardFace.Size.small, .medium, .large] {
            let view = CardFace(text: long, isBack: true, size: size)
                .frame(width: 300, height: 160)
            let renderer = ImageRenderer(content: view)
            var image: CGImage?
            let elapsed = seconds { image = renderer.cgImage }
            XCTAssertNotNil(image)
            XCTAssertLessThan(elapsed, 3, "\(size)")
        }
    }
}

/// Sleep and clock changes: the notch's one timer was set against the old time.
@MainActor
final class NotchWakeTests: XCTestCase {
    private var root: URL!
    private var now = Date(timeIntervalSince1970: 100)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController() throws -> NotchController {
        let deck = Deck(name: "Spanish", color: .green, cards: (1...5).map { Card(front: "s\($0)", back: "answer s\($0)") })
        try DeckStorage(directory: root).save([deck])
        let decks = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let far = ScreenMetrics(
            frame: CGRect(x: -70_000, y: 0, width: 1710, height: 1107),
            visibleFrame: CGRect(x: -70_000, y: 0, width: 1710, height: 1073.5),
            safeAreaTop: 33.5,
            auxiliaryTopLeft: CGRect(x: -70_000, y: 1073.5, width: 762.5, height: 33.5),
            auxiliaryTopRight: CGRect(x: -70_000 + 947.5, y: 1073.5, width: 762.5, height: 33.5)
        )
        let controller = NotchController(
            placementProvider: { NotchGeometry.placement(for: far) },
            showsPanel: false, installsMonitors: false, watchDirectory: root,
            clock: { [unowned self] in now },
            deckStore: { decks }, playbackStore: { playback }, settingsStore: { settings }
        )
        addTeardownBlock { controller.stop() }
        return controller
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    func testWakingFromSleepShowsTheCurrentCard() throws {
        let controller = try makeController()
        controller.start()
        let before = controller.model.showing?.position

        now = now.addingTimeInterval(3 * 300) // asleep for three rotations
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        settle()

        XCTAssertNotEqual(controller.model.showing?.position, before)
        XCTAssertEqual(controller.model.nextRotation, CardScheduler().nextRotation(after: now))
    }

    func testChangingTheClockOrTimeZoneRefreshesToo() throws {
        let controller = try makeController()
        controller.start()

        now = now.addingTimeInterval(300)
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        settle()
        XCTAssertEqual(controller.model.nextRotation, CardScheduler().nextRotation(after: now))

        now = now.addingTimeInterval(300)
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        settle()
        XCTAssertEqual(controller.model.nextRotation, CardScheduler().nextRotation(after: now))
    }

    func testAStoppedNotchIgnoresWakeEvents() throws {
        let controller = try makeController()
        controller.start()
        controller.stop()
        let shown = controller.model.nextRotation
        now = now.addingTimeInterval(600)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        settle()
        XCTAssertEqual(controller.model.nextRotation, shown)
    }
}

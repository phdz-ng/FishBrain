import AppKit
import SwiftUI
import XCTest

final class SpokenTextTests: XCTestCase {
    func testTheFrontIsReadAsWrittenAndTheBackAsTheAnswer() {
        XCTAssertEqual(CardFace.accessibilityText("la sobremesa", isBack: false), "la sobremesa")
        XCTAssertEqual(CardFace.accessibilityText("lingering at the table", isBack: true), "Answer, lingering at the table")
    }

    func testBlankCardsAreAnnouncedNotSilent() {
        XCTAssertEqual(CardFace.accessibilityText("", isBack: false), "Blank card")
        XCTAssertEqual(CardFace.accessibilityText("  \n", isBack: false), "Blank card")
        XCTAssertEqual(CardFace.accessibilityText("", isBack: true), "Answer, blank")
    }

    func testSurroundingWhitespaceIsNotRead() {
        XCTAssertEqual(CardFace.accessibilityText("  hola \n", isBack: false), "hola")
    }

    func testTheDeckRowIsReadWithItsCardCount() {
        XCTAssertEqual(SidebarRow.accessibilityText(name: "Everyday Spanish", count: 48), "Everyday Spanish, 48 cards")
        XCTAssertEqual(SidebarRow.accessibilityText(name: "Tiny", count: 1), "Tiny, 1 card")
        XCTAssertEqual(SidebarRow.accessibilityText(name: "Empty", count: 0), "Empty, 0 cards")
    }

    func testTheNotchAndWidgetHeaderSummary() {
        let deck = Deck(name: "Everyday Spanish", cards: (1...48).map { Card(front: "f\($0)", back: "b\($0)") })
        let now = Date(timeIntervalSince1970: 11 * 300)
        let showing = NowShowing.make(deck: deck, state: PlaybackState(), at: now)
        XCTAssertEqual(showing?.accessibilitySummary, "Everyday Spanish, card 12 of 48")
    }
}

final class ReduceMotionTests: XCTestCase {
    func testReduceMotionTurnsTheFlipIntoACrossfade() {
        XCTAssertEqual(NotchCard.flipStyle(reduceMotion: false), .rotate)
        XCTAssertEqual(NotchCard.flipStyle(reduceMotion: true), .crossfade)
    }

    func testARotatingFlipShowsExactlyOneFaceAtATime() {
        for angle in stride(from: 0.0, through: 180.0, by: 5.0) {
            let o = NotchCard.faceOpacities(angle: angle, style: .rotate)
            XCTAssertEqual(o.front + o.back, 1, "angle \(angle)")
        }
        XCTAssertEqual(NotchCard.faceOpacities(angle: 0, style: .rotate).front, 1)
        XCTAssertEqual(NotchCard.faceOpacities(angle: 180, style: .rotate).back, 1)
    }

    func testACrossfadeTradesTheFacesSmoothlyAndNeverRotates() {
        XCTAssertEqual(NotchCard.faceOpacities(angle: 0, style: .crossfade).front, 1)
        XCTAssertEqual(NotchCard.faceOpacities(angle: 0, style: .crossfade).back, 0)
        XCTAssertEqual(NotchCard.faceOpacities(angle: 90, style: .crossfade).front, 0.5, accuracy: 0.0001)
        XCTAssertEqual(NotchCard.faceOpacities(angle: 90, style: .crossfade).back, 0.5, accuracy: 0.0001)
        XCTAssertEqual(NotchCard.faceOpacities(angle: 180, style: .crossfade).back, 1)

        var previous = 1.0
        for angle in stride(from: 0.0, through: 180.0, by: 10.0) {
            let front = NotchCard.faceOpacities(angle: angle, style: .crossfade).front
            XCTAssertLessThanOrEqual(front, previous, "fades monotonically")
            previous = front
        }
    }

    func testOutOfRangeAnglesStayInRange() {
        for angle in [-30.0, 400.0] {
            let o = NotchCard.faceOpacities(angle: angle, style: .crossfade)
            XCTAssertTrue((0...1).contains(o.front) && (0...1).contains(o.back))
        }
    }
}

final class KeyboardNavigationTests: XCTestCase {
    private let decks = (1...4).map { Deck(name: "Deck \($0)") }

    func testDownAndUpMoveOneDeck() {
        XCTAssertEqual(DeckSelection.neighbor(of: decks[1].id, in: decks, step: 1), decks[2].id)
        XCTAssertEqual(DeckSelection.neighbor(of: decks[1].id, in: decks, step: -1), decks[0].id)
    }

    func testItStopsAtTheEndsInsteadOfWrapping() {
        XCTAssertEqual(DeckSelection.neighbor(of: decks[3].id, in: decks, step: 1), decks[3].id)
        XCTAssertEqual(DeckSelection.neighbor(of: decks[0].id, in: decks, step: -1), decks[0].id)
    }

    func testWithNothingSelectedDownPicksTheFirstAndUpTheLast() {
        XCTAssertEqual(DeckSelection.neighbor(of: nil, in: decks, step: 1), decks[0].id)
        XCTAssertEqual(DeckSelection.neighbor(of: nil, in: decks, step: -1), decks[3].id)
        XCTAssertEqual(DeckSelection.neighbor(of: UUID(), in: decks, step: 1), decks[0].id, "a deleted selection counts as none")
    }

    func testNoDecksNoNeighbor() {
        XCTAssertNil(DeckSelection.neighbor(of: nil, in: [], step: 1))
    }
}

@MainActor
final class CommandCenterTests: XCTestCase {
    func testCommandsAreGreyedOutUntilTheWindowRegistersThem() {
        let center = CommandCenter()
        XCTAssertNil(center.newDeck)
        XCTAssertNil(center.addCard)
        XCTAssertNil(center.focusSearch)
    }

    func testRegisteredCommandsRunAndClearingRemovesThem() {
        let center = CommandCenter()
        var ran: [String] = []
        center.newDeck = { ran.append("new") }
        center.addCard = { ran.append("add") }
        center.focusSearch = { ran.append("find") }

        center.newDeck?()
        center.addCard?()
        center.focusSearch?()
        XCTAssertEqual(ran, ["new", "add", "find"])

        center.clear()
        XCTAssertNil(center.newDeck)
        XCTAssertNil(center.addCard)
        XCTAssertNil(center.focusSearch)
    }
}

/// Every icon-only control must say what it is to VoiceOver. This reads the source: each
/// `Image(systemName:)` has to be given a label, or be marked decorative, close by.
final class IconLabelLintTests: XCTestCase {
    func testEveryIconIsLabeledOrMarkedDecorative() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var checked = 0
        var unlabeled: [String] = []

        for dir in ["FishBrain", "Shared"] {
            let base = root.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for file in files where file.pathExtension == "swift" {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (i, line) in lines.enumerated() where line.contains("Image(systemName:") {
                    checked += 1
                    let window = lines[max(0, i - 2)..<min(lines.count, i + 14)].joined(separator: "\n")
                    if !window.contains("accessibilityLabel") && !window.contains("accessibilityHidden") {
                        unlabeled.append("\(file.lastPathComponent):\(i + 1)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 5, "the lint found no icons; check the path logic")
        XCTAssertEqual(unlabeled, [], "icons with no accessibility label or hidden marker")
    }
}

@MainActor
final class NotchAccessibilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try DeckStorage(directory: root).save([Deck(name: "Spanish", cards: [Card(front: "hola", back: "hello")])])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController() -> NotchController {
        let screen = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
            visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073.5),
            safeAreaTop: 33.5,
            auxiliaryTopLeft: CGRect(x: 0, y: 1073.5, width: 762.5, height: 33.5),
            auxiliaryTopRight: CGRect(x: 947.5, y: 1073.5, width: 762.5, height: 33.5)
        )
        let decks = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let controller = NotchController(
            placementProvider: { NotchGeometry.placement(for: screen) }, showsPanel: false, installsMonitors: false,
            collapseAnimation: .milliseconds(10), watchDirectory: root,
            deckStore: { decks }, playbackStore: { playback }, settingsStore: { settings }
        )
        addTeardownBlock { controller.stop() }
        return controller
    }

    /// Hovering is the only mouse way in, so VoiceOver gets the same through an action.
    func testTheNotchCanBeOpenedAndClosedWithoutHovering() async throws {
        let controller = makeController()
        controller.start()
        XCTAssertFalse(controller.model.isExpanded)

        controller.model.onToggleExpanded()
        XCTAssertTrue(controller.model.isExpanded)
        XCTAssertEqual(controller.panel?.ignoresMouseEvents, false, "open, so its buttons can be activated")

        controller.model.onToggleExpanded()
        XCTAssertFalse(controller.model.isExpanded)
        await controller.pendingFinishCollapse?.value
        XCTAssertEqual(controller.panel?.ignoresMouseEvents, true)
    }

    func testThePanelHasAnAccessibleName() {
        let controller = makeController()
        controller.start()
        XCTAssertEqual(controller.panel?.accessibilityLabel(), "FishBrain notch")
    }
}

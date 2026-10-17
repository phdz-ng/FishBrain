import AppKit
import SwiftUI
import XCTest

final class DeckSummaryTests: XCTestCase {
    func testSubtitleMatchesTheDesignText() {
        XCTAssertEqual(
            DeckSummary.subtitle(cardCount: 48, widgetCount: 2, showsInNotch: true),
            "48 cards, showing in 2 widgets and the notch"
        )
    }

    func testSubtitlePluralization() {
        XCTAssertEqual(
            DeckSummary.subtitle(cardCount: 1, widgetCount: 1, showsInNotch: true),
            "1 card, showing in 1 widget and the notch"
        )
        XCTAssertEqual(
            DeckSummary.subtitle(cardCount: 0, widgetCount: 3, showsInNotch: false),
            "0 cards, showing in 3 widgets"
        )
    }

    func testSubtitleWithOnlyTheNotchOrNowhere() {
        XCTAssertEqual(DeckSummary.subtitle(cardCount: 5, widgetCount: 0, showsInNotch: true), "5 cards, showing in the notch")
        XCTAssertEqual(DeckSummary.subtitle(cardCount: 5, widgetCount: 0, showsInNotch: false), "5 cards")
    }
}

final class DeckSelectionTests: XCTestCase {
    private let decks = [Deck(name: "A"), Deck(name: "B"), Deck(name: "C")]

    func testKeepsTheSelectedDeck() {
        XCTAssertEqual(DeckSelection.resolve(decks[1].id, in: decks)?.name, "B")
    }

    func testFallsBackToTheFirstDeckWhenNothingOrADeletedDeckIsSelected() {
        XCTAssertEqual(DeckSelection.resolve(nil, in: decks)?.name, "A")
        XCTAssertEqual(DeckSelection.resolve(UUID(), in: decks)?.name, "A")
    }

    func testNoDecksMeansNoSelection() {
        XCTAssertNil(DeckSelection.resolve(nil, in: []))
    }
}

@MainActor
final class MainWindowRenderTests: XCTestCase {
    private func render(decks: [Deck], size: CGSize, accent: AccentChoice = .default) throws -> CGImage {
        let view = MainWindowView()
            .environmentObject(PreviewData.store(decks: decks))
            .environmentObject(PreviewData.playback())
            .environmentObject(PreviewData.study())
            .environmentObject(PreviewData.runHistory())
            .environmentObject(PreviewData.studyClock())
            .environmentObject(PreviewData.settings())
            .environmentObject(PreviewData.composer())
            .environment(\.accentChoice, accent)
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func dump(_ image: CGImage, named name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["FISHBRAIN_SNAPSHOT_DIR"] else { return }
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try data?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testLaysOutAtMinimumAndLargeSizesWithAndWithoutDecks() throws {
        let minimum = MainWindowView.minimumSize
        let cases: [(String, [Deck], CGSize)] = [
            ("window-min", PreviewData.decks, minimum),
            ("window-large", PreviewData.decks, CGSize(width: 1280, height: 800)),
            ("window-empty", [], CGSize(width: 1040, height: 680)),
        ]
        for (name, decks, size) in cases {
            let image = try render(decks: decks, size: size)
            XCTAssertEqual(image.width, Int(size.width), name)
            XCTAssertEqual(image.height, Int(size.height), name)
            try dump(image, named: name)
        }
    }
}

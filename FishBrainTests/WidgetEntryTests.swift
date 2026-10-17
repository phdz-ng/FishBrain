import AppKit
import SwiftUI
import WidgetKit
import XCTest

final class WidgetEntryTests: XCTestCase {
    private let scheduler = CardScheduler()
    private func deck(_ name: String, cards: Int) -> Deck {
        Deck(name: name, color: .green, cards: (1...max(cards, 1)).prefix(cards).map { Card(front: "f\($0)", back: "b\($0)") })
    }
    private func at(slot: Int, plus seconds: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: Double(slot) * scheduler.interval + seconds)
    }

    func testShowsTheFirstDeckAndTheCardForTheCurrentSlot() {
        let decks = [deck("First", cards: 5), deck("Second", cards: 5)]
        let entry = FishBrainEntry.make(decks: decks, playback: [:], accent: .teal, at: at(slot: 2, plus: 30))

        XCTAssertEqual(entry.showing?.deckName, "First")
        XCTAssertEqual(entry.showing?.deckColor, .green)
        XCTAssertEqual(entry.showing?.card.front, "f3")
        XCTAssertEqual(entry.accent, .teal)
        XCTAssertEqual(entry.nextRotation, at(slot: 3))
    }

    func testAppliesTheDecksPlaybackState() {
        let decks = [deck("First", cards: 5)]
        let t = at(slot: 0, plus: 10)
        let state = scheduler.flipping(scheduler.skipping(PlaybackState(), in: decks[0], at: t), in: decks[0], at: t)
        let entry = FishBrainEntry.make(decks: decks, playback: [decks[0].id: state], accent: .indigo, at: t)

        XCTAssertEqual(entry.showing?.card.front, "f2")
        XCTAssertEqual(entry.showing?.isFlipped, true)
    }

    func testNoDecksOrNoCardsMeansNothingToShow() {
        XCTAssertNil(FishBrainEntry.make(decks: [], playback: [:], accent: .indigo, at: at(slot: 0)).showing)
        XCTAssertNil(FishBrainEntry.make(decks: [Deck(name: "Empty")], playback: [:], accent: .indigo, at: at(slot: 0)).showing)
    }

    func testSampleEntriesAreFullyPopulated() {
        XCTAssertEqual(FishBrainEntry.sample.showing?.positionText.hasSuffix("/48"), true)
        XCTAssertEqual(FishBrainEntry.sample(flipped: true).showing?.isFlipped, true)
        XCTAssertEqual(FishBrainEntry.sample(accent: .teal).accent, .teal)
        XCTAssertGreaterThan(FishBrainEntry.sample(longText: true).showing?.card.front.count ?? 0, 60)
    }
}

@MainActor
final class WidgetViewRenderTests: XCTestCase {
    private static let sizes: [(WidgetFamily, CGSize)] = [
        (.systemSmall, CGSize(width: 158, height: 158)),
        (.systemMedium, CGSize(width: 338, height: 158)),
        (.systemLarge, CGSize(width: 338, height: 354)),
    ]

    private func render(_ entry: FishBrainEntry, family: WidgetFamily, size: CGSize) throws -> CGImage {
        let view = FishBrainWidgetContent(entry: entry, family: family)
            .frame(width: size.width, height: size.height)
            .background(Theme.Surface.widget)
            .preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    func testEveryFamilyRendersEveryStateAtItsSize() throws {
        let entries: [(String, FishBrainEntry)] = [
            ("front", .sample()),
            ("back", .sample(flipped: true)),
            ("long", .sample(longText: true)),
            ("long-back", .sample(flipped: true, longText: true)),
            ("empty", FishBrainEntry.make(decks: [], playback: [:], accent: .indigo, at: Date())),
            ("empty-deck", FishBrainEntry.make(decks: [Deck(name: "Everyday Spanish")], playback: [:], accent: .teal, at: Date())),
            ("empty-deck-long-name", FishBrainEntry.make(decks: [Deck(name: "An extremely long deck name that goes on and on")], playback: [:], accent: .indigo, at: Date())),
        ]
        for (family, size) in Self.sizes {
            for (name, entry) in entries {
                let image = try render(entry, family: family, size: size)
                XCTAssertEqual(image.width, Int(size.width * 2), "\(family) \(name)")
                XCTAssertEqual(image.height, Int(size.height * 2), "\(family) \(name)")

                if let dir = ProcessInfo.processInfo.environment["FISHBRAIN_SNAPSHOT_DIR"] {
                    let file = URL(fileURLWithPath: dir).appendingPathComponent("widget-\(family.description)-\(name).png")
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
                }
            }
        }
    }
}

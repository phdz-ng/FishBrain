import AppKit
import SwiftUI
import WidgetKit
import XCTest

/// FLAS-108: the small widget shows the deck's color icon before its name.
@MainActor
final class SmallWidgetIconTests: XCTestCase {
    private let size = CGSize(width: 158, height: 158)
    private let longName = "Spanish irregular verbs in the past tense"

    /// The widget sets its own light or dark from the entry's appearance, so that is what picks the scheme.
    private func render(_ entry: FishBrainEntry) throws -> NSBitmapImageRep {
        let scheme = entry.appearance
        let view = FishBrainWidgetContent(entry: entry, family: .systemSmall)
            .frame(width: size.width, height: size.height)
            .background(Theme.Surface.widget)
            .environment(\.colorScheme, scheme.colorScheme ?? .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        if let dir = ProcessInfo.processInfo.environment["FISHBRAIN_SNAPSHOT_DIR"] {
            let flipped = entry.showing?.isFlipped == true ? "back" : "front"
            let file = URL(fileURLWithPath: dir).appendingPathComponent("widget-small-icon-\(flipped)-\(scheme).png")
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
        }
        return NSBitmapImageRep(cgImage: image)
    }

    /// Whether any pixel in the header's leading corner (where the icon sits) is the expected color.
    private func headerContains(_ swatch: Swatch, in rep: NSBitmapImageRep) -> Bool {
        // 14 pt padding, a 14 pt icon: look at 12...30 pt across and down, at 2x.
        for x in 24..<60 {
            for y in 24..<60 {
                // colorAt hands back the stored sRGB values as they are.
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if abs(c.redComponent - swatch.red) < 0.01, abs(c.greenComponent - swatch.green) < 0.01,
                   abs(c.blueComponent - swatch.blue) < 0.01 {
                    return true
                }
            }
        }
        return false
    }

    func testTheIconIsSmallerThanTheMediumAndLargeOnes() {
        XCTAssertEqual(SmallWidgetContent.iconSize, 14)
    }

    func testTheIconUsesTheDecksColorFrontAndBackInLightAndDark() throws {
        let fill = DeckColor.green.fill(accent: .default)
        for (appearance, swatch, other) in [(AppearanceChoice.light, fill.light, fill.dark), (.dark, fill.dark, fill.light)] {
            for flipped in [false, true] {
                let entry = FishBrainEntry.sample(flipped: flipped, appearance: appearance, deckName: longName, deckColor: .green)
                let rep = try render(entry)
                XCTAssertTrue(headerContains(swatch, in: rep), "\(appearance) flipped: \(flipped)")
                XCTAssertFalse(headerContains(other, in: rep), "\(appearance) flipped: \(flipped) uses the other theme's green")
            }
        }
    }

    func testADifferentDeckColorGivesADifferentIcon() throws {
        let purple = DeckColor.purple.fill(accent: .default).dark
        let green = try render(FishBrainEntry.sample(appearance: .dark, deckColor: .green))
        XCTAssertFalse(headerContains(purple, in: green))
        let purpleDeck = try render(FishBrainEntry.sample(appearance: .dark, deckColor: .purple))
        XCTAssertTrue(headerContains(purple, in: purpleDeck))
    }

    func testALongNameStillRendersAtTheWidgetsSize() throws {
        let rep = try render(FishBrainEntry.sample(deckName: longName, deckColor: .orange))
        XCTAssertEqual(rep.pixelsWide, Int(size.width * 2))
        XCTAssertEqual(rep.pixelsHigh, Int(size.height * 2))
    }
}

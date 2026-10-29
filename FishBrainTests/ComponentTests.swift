import AppKit
import SwiftUI
import XCTest

@MainActor
final class ComponentTests: XCTestCase {
    /// Renders at 2x so thin strokes and small fills are sampleable.
    private func render<V: View>(_ view: V, accent: AccentChoice = .default, scheme: ColorScheme = .dark) throws -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.accentChoice, accent).environment(\.colorScheme, scheme))
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    /// The pixel at (x, y) in points, as sRGB bytes.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: Double, g: Double, b: Double, a: Double) {
        let rep = NSBitmapImageRep(cgImage: image)
        let color = try XCTUnwrap(rep.colorAt(x: x * 2, y: y * 2)?.usingColorSpace(.sRGB))
        return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
    }

    /// Which accent's fill (or `light`) the pixel is closest to.
    private func nearestAccent(
        _ rgb: (r: Double, g: Double, b: Double, a: Double), using style: (AccentChoice) -> Token, scheme: ColorScheme = .dark
    ) -> AccentChoice {
        func distance(_ token: Token) -> Double {
            let t = token.swatch(for: scheme)
            return pow(t.red - rgb.r, 2) + pow(t.green - rgb.g, 2) + pow(t.blue - rgb.b, 2)
        }
        return AccentChoice.allCases.min { distance(style($0)) < distance(style($1)) }!
    }

    // MARK: Accent applies everywhere

    func testPrimaryButtonFollowsAccent() throws {
        for scheme in [ColorScheme.light, .dark] {
            for accent in AccentChoice.allCases {
                let image = try render(Button("Add Card") {}.buttonStyle(.capsulePrimary), accent: accent, scheme: scheme)
                let p = try pixel(image, x: 12, y: 17) // inside the capsule, left of the label
                XCTAssertEqual(nearestAccent(p, using: \.fill, scheme: scheme), accent, "\(scheme)")
            }
        }
    }

    /// The same view drawn in light and in dark picks each appearance's value.
    func testComponentsDrawTheValueForTheirAppearance() throws {
        let control = Theme.Surface.control
        let light = try pixel(render(Button("Import") {}.buttonStyle(.capsuleSecondary), scheme: .light), x: 12, y: 17)
        let dark = try pixel(render(Button("Import") {}.buttonStyle(.capsuleSecondary), scheme: .dark), x: 12, y: 17)
        XCTAssertEqual(light.a, control.light.opacity, accuracy: 0.02)
        XCTAssertEqual(dark.a, control.dark.opacity, accuracy: 0.02)

        let lightRow = try pixel(render(SidebarRow(name: "Deck", count: 3, color: .green).frame(width: 200)
            .background(AccentChoice.orange.sidebar), scheme: .light), x: 100, y: 3)
        XCTAssertEqual(lightRow.r, 1, accuracy: 0.02, "light sidebar is the pale orange tint")
        XCTAssertLessThan(lightRow.b, 0.96)
    }

    func testSecondaryButtonIgnoresAccent() throws {
        let indigo = try pixel(render(Button("Import") {}.buttonStyle(.capsuleSecondary), accent: .indigo), x: 12, y: 17)
        let teal = try pixel(render(Button("Import") {}.buttonStyle(.capsuleSecondary), accent: .teal), x: 12, y: 17)
        XCTAssertEqual(indigo.r, teal.r, accuracy: 0.01)
        XCTAssertEqual(indigo.b, teal.b, accuracy: 0.01)
    }

    func testSelectedSidebarRowFollowsAccent() throws {
        for accent in AccentChoice.allCases {
            let row = SidebarRow(name: "Deck", count: 3, color: .green, isSelected: true).frame(width: 200)
            let p = try pixel(render(row, accent: accent), x: 3, y: 18)
            XCTAssertEqual(nearestAccent(p, using: \.fill), accent)
        }
    }

    func testAccentDeckIconFollowsAccentButNamedColorsDoNot() throws {
        for accent in AccentChoice.allCases {
            let p = try pixel(render(DeckIcon(color: .accent, size: 40), accent: accent), x: 4, y: 20)
            XCTAssertEqual(nearestAccent(p, using: \.fill), accent)
        }
        let underIndigo = try pixel(render(DeckIcon(color: .green, size: 40), accent: .indigo), x: 4, y: 20)
        let underTeal = try pixel(render(DeckIcon(color: .green, size: 40), accent: .teal), x: 4, y: 20)
        XCTAssertEqual(underIndigo.r, underTeal.r, accuracy: 0.01)
        XCTAssertEqual(underIndigo.g, underTeal.g, accuracy: 0.01)
        XCTAssertEqual(underIndigo.b, underTeal.b, accuracy: 0.01)
    }

    func testProgressFillFollowsAccent() throws {
        for accent in AccentChoice.allCases {
            let bar = CountdownProgressBar(progress: 1, height: 8).frame(width: 100)
            let p = try pixel(render(bar, accent: accent), x: 50, y: 4)
            XCTAssertEqual(nearestAccent(p, using: \.light), accent)
        }
    }

    // MARK: Behavior

    func testProgressIsClamped() {
        XCTAssertEqual(CountdownProgressBar.clamped(-0.5), 0)
        XCTAssertEqual(CountdownProgressBar.clamped(0.4), 0.4)
        XCTAssertEqual(CountdownProgressBar.clamped(7), 1)
        XCTAssertEqual(CountdownProgressBar.clamped(.nan), 0)
    }

    /// WidgetKit can hand a view an infinite or NaN width while laying a widget out; the bar must draw
    /// nothing then, not feed NaN into the layout (which crashed the widget extension).
    func testTheBarsFillWidthIsNeverNaNOrInfinite() {
        XCTAssertEqual(CountdownProgressBar.fillWidth(trackWidth: 200, progress: 0.5), 100)
        XCTAssertEqual(CountdownProgressBar.fillWidth(trackWidth: 200, progress: 0), 0)
        XCTAssertEqual(CountdownProgressBar.fillWidth(trackWidth: 200, progress: 1), 200)
        XCTAssertEqual(CountdownProgressBar.fillWidth(trackWidth: 200, progress: 7), 200, "clamped")

        XCTAssertEqual(CountdownProgressBar.fillWidth(trackWidth: .infinity, progress: 0), 0, "infinity * 0 would be NaN")
        XCTAssertEqual(CountdownProgressBar.fillWidth(trackWidth: .infinity, progress: 0.5), 0)
        XCTAssertEqual(CountdownProgressBar.fillWidth(trackWidth: .nan, progress: 0.5), 0)
        XCTAssertEqual(CountdownProgressBar.fillWidth(trackWidth: -10, progress: 0.5), 0)
        XCTAssertEqual(CountdownProgressBar.fillWidth(trackWidth: 200, progress: .nan), 0)
    }

    func testProgressBarFillsProportionally() throws {
        let bar = CountdownProgressBar(progress: 0.5, height: 8).frame(width: 100)
        let image = try render(bar)
        let filled = try pixel(image, x: 25, y: 4)
        let empty = try pixel(image, x: 75, y: 4)
        XCTAssertEqual(nearestAccent(filled, using: \.light), .default)
        XCTAssertGreaterThan(filled.a, 0.95)
        XCTAssertLessThan(empty.a, 0.3, "unfilled part shows only the faint track")
    }

    func testStackGlyphStaysInsideItsFrame() {
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        XCTAssertTrue(rect.contains(StackGlyph().path(in: rect).boundingRect))
    }

    func testEveryComponentRendersForEveryAccent() throws {
        for accent in AccentChoice.allCases {
            let image = try render(ComponentGallery(accent: accent), accent: accent)
            XCTAssertGreaterThan(image.width, image.height, "light and dark side by side")
            XCTAssertGreaterThan(image.width, 100)
            XCTAssertGreaterThan(image.height, 100)

            // Optional: dump PNGs for eyeballing (TEST_RUNNER_FISHBRAIN_SNAPSHOT_DIR=/some/dir).
            if let dir = ProcessInfo.processInfo.environment["FISHBRAIN_SNAPSHOT_DIR"] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("gallery-\(accent.rawValue).png")
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                try data?.write(to: url)
            }
        }
    }
}

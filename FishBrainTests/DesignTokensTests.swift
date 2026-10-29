import SwiftUI
import XCTest

final class DesignTokensTests: XCTestCase {
    private let schemes: [ColorScheme] = [.light, .dark]

    /// The darkest possible backdrop. In dark, translucent surfaces get lighter over anything brighter,
    /// so dark is checked as it looks over black (the intended look). In light, black is the worst case
    /// for the dark text: the glass is at its darkest there.
    private let black = Swatch(0x000000)

    private func window(_ scheme: ColorScheme) -> Swatch { Theme.Surface.window.swatch(for: scheme).composited(over: black) }

    private func surfaces(_ scheme: ColorScheme, accent: AccentChoice) -> [(name: String, swatch: Swatch)] {
        let window = window(scheme)
        return [
            ("window", window),
            ("sidebar", accent.sidebar.swatch(for: scheme).composited(over: window)),
            ("group", Theme.Surface.group.swatch(for: scheme).composited(over: window)),
            ("widget", Theme.Surface.widget.swatch(for: scheme).composited(over: black)),
        ]
    }

    /// Light with every accent, and dark with every accent.
    private var palettes: [(scheme: ColorScheme, accent: AccentChoice)] {
        schemes.flatMap { scheme in AccentChoice.allCases.map { (scheme, $0) } }
    }

    private func assertContrast(
        _ text: Token, on surface: Swatch, in scheme: ColorScheme, atLeast minimum: Double = 4.5, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let ratio = text.swatch(for: scheme).composited(over: surface).contrast(with: surface)
        XCTAssertGreaterThanOrEqual(ratio, minimum, "\(label) in \(scheme): \(ratio)", file: file, line: line)
    }

    // MARK: Spec values

    /// Dark is the original design, unchanged.
    func testDarkValuesMatchTheOriginalDesign() {
        XCTAssertEqual(Theme.Surface.window.dark, Swatch(0x16161A, opacity: 0.82))
        XCTAssertEqual(Theme.Surface.sidebar.dark, Swatch(0x28282E, opacity: 0.60))
        XCTAssertEqual(Theme.Surface.group.dark, Swatch(0x2C2C32, opacity: 0.70))
        XCTAssertEqual(Theme.Surface.hairline.dark, Swatch(0xFFFFFF, opacity: 0.08))
        XCTAssertEqual(Theme.TextColor.primary.dark, Swatch(0xFFFFFF))
        XCTAssertEqual(Theme.TextColor.secondary.dark, Swatch(0x8D8D93))
        XCTAssertEqual(Theme.TextColor.cardBack.dark, Swatch(0xC7C7CC))
        XCTAssertEqual(AccentChoice.indigo.fill.dark, Swatch(0x5E5CE6))
        XCTAssertEqual(AccentChoice.indigo.light.dark, Swatch(0xA5A3FF))
        XCTAssertEqual(AccentChoice.blue.fill.dark, Swatch(0x0A6CDB))
        // Purple and teal are the canvas colors darkened just enough for white text to reach 4.5:1.
        XCTAssertEqual(AccentChoice.purple.fill.dark, Swatch(0xA54ED5))
        XCTAssertEqual(AccentChoice.teal.fill.dark, Swatch(0x168195))
        XCTAssertEqual(AccentChoice.indigo.flippedSurface.dark, Swatch(0x26254A))
        XCTAssertEqual(DeckColor.green.fill(accent: .indigo).dark, Swatch(0x248A3D))
        XCTAssertEqual(DeckColor.purple.fill(accent: .indigo).dark, Swatch(0xA64FD6))
        for accent in AccentChoice.allCases {
            XCTAssertEqual(accent.sidebar.dark, Theme.Surface.sidebar.dark, "dark sidebar is the same glass for every accent")
        }
    }

    /// FLAS-79: Tangerine and white.
    func testLightValuesMatchTheEpic() {
        XCTAssertEqual(Theme.Surface.window.light.with(opacity: 1), Swatch(0xFFFFFF))
        XCTAssertEqual(Theme.Surface.group.light.with(opacity: 1), Swatch(0xFFFFFF))
        XCTAssertEqual(Theme.TextColor.primary.light, Swatch(0x1F1A17))
        XCTAssertEqual(Theme.TextColor.secondary.light, Swatch(0x6E655E))
        let table: [(AccentChoice, fill: UInt32, sidebar: UInt32, darkFill: UInt32, darkText: UInt32, darkFlipped: UInt32)] = [
            (.orange, 0xC2410C, 0xFFF4EC, 0xC2410C, 0xFFA36B, 0x3D2418),
            (.indigo, 0x4F4CD8, 0xF4F4FB, 0x5E5CE6, 0xA5A3FF, 0x26254A),
            (.blue, 0x0A66D6, 0xF1F6FD, 0x0A6CDB, 0x70B7FF, 0x18304D),
            (.purple, 0x8E3CC2, 0xF7F1FB, 0xA54ED5, 0xDA9BF8, 0x3A2448),
            (.teal, 0x0F766E, 0xEEF7F6, 0x168195, 0x7FDCEB, 0x173A40),
        ]
        for row in table {
            XCTAssertEqual(row.0.fill.light, Swatch(row.fill), "\(row.0) light fill")
            XCTAssertEqual(row.0.light.light, Swatch(row.fill), "\(row.0) light text is the fill")
            XCTAssertEqual(row.0.sidebar.light.with(opacity: 1), Swatch(row.sidebar), "\(row.0) sidebar tint")
            XCTAssertEqual(row.0.fill.dark, Swatch(row.darkFill), "\(row.0) dark fill")
            XCTAssertEqual(row.0.light.dark, Swatch(row.darkText), "\(row.0) dark text")
            XCTAssertEqual(row.0.flippedSurface.dark, Swatch(row.darkFlipped), "\(row.0) dark flipped card")
        }
    }

    func testOrangeIsTheDefaultAndFirstAccent() {
        XCTAssertEqual(AccentChoice.default, .orange)
        XCTAssertEqual(AccentChoice.allCases, [.orange, .indigo, .blue, .purple, .teal], "the order of the swatches")
    }

    func testUnknownAccentDecodesAsOrange() throws {
        let decoded = try JSONDecoder().decode([AccentChoice].self, from: Data(#"["chartreuse","teal"]"#.utf8))
        XCTAssertEqual(decoded, [.orange, .teal])
    }

    func testRadiiMatchTheDesign() {
        XCTAssertEqual(Theme.Radius.window, 16)
        XCTAssertEqual(Theme.Radius.group, 14)
        XCTAssertEqual(Theme.Radius.widget, 22)
    }

    func testAccentDeckColorFollowsTheAccentChoice() {
        for accent in AccentChoice.allCases {
            XCTAssertEqual(DeckColor.accent.fill(accent: accent), accent.fill)
        }
    }

    // MARK: Resolution

    /// Every token has its own light value: none is left at the dark one by mistake. The ones that are
    /// the same in both on purpose are listed.
    func testLightHasItsOwnValueForEveryToken() {
        let sameOnPurpose: Set<String> = ["onAccentIcon", "notch", "onAccent", "orange fill"]
        var tokens: [(String, Token)] = [
            ("window", Theme.Surface.window), ("group", Theme.Surface.group), ("hairline", Theme.Surface.hairline),
            ("widget", Theme.Surface.widget), ("control", Theme.Surface.control), ("progressTrack", Theme.Surface.progressTrack),
            ("segmentSelected", Theme.Surface.segmentSelected), ("onAccentIcon", Theme.Surface.onAccentIcon),
            ("switchOn", Theme.Surface.switchOn), ("notch", Theme.Surface.notch), ("previewBackdrop", Theme.Surface.previewBackdrop),
            ("ok", Theme.Status.ok), ("problem", Theme.Status.problem), ("learning", Theme.Status.learning),
            ("flame", Theme.Streak.flame),
            ("primary", Theme.TextColor.primary), ("secondary", Theme.TextColor.secondary), ("cardBack", Theme.TextColor.cardBack),
            ("onControl", Theme.TextColor.onControl), ("onAccent", Theme.TextColor.onAccent),
        ]
        for accent in AccentChoice.allCases {
            tokens += [
                ("\(accent) fill", accent.fill), ("\(accent) text", accent.light),
                ("\(accent) flipped", accent.flippedSurface), ("\(accent) sidebar", accent.sidebar),
            ]
        }
        for color in DeckColor.allCases where color != .accent { tokens.append(("deck \(color)", color.fill(accent: .default))) }
        for (name, token) in tokens where !sameOnPurpose.contains(name) {
            XCTAssertNotEqual(token.light, token.dark, "\(name) has no light value of its own")
        }
    }

    func testATokenResolvesToTheValueForTheEnvironmentsScheme() {
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        XCTAssertEqual(Theme.TextColor.primary.resolve(in: environment), Swatch(0x1F1A17).color)
        XCTAssertEqual(AccentChoice.orange.sidebar.resolve(in: environment), Swatch(0xFFF4EC, opacity: 0.94).color)
        environment.colorScheme = .dark
        XCTAssertEqual(Theme.TextColor.primary.resolve(in: environment), Swatch(0xFFFFFF).color)
        XCTAssertEqual(AccentChoice.orange.light.resolve(in: environment), Swatch(0xFFA36B).color)
    }

    func testGlassGoesSolidWithReduceTransparencyAndIncreaseContrast() {
        let window = Theme.Surface.window
        for scheme in schemes {
            XCTAssertLessThan(window.swatch(for: scheme, reduceTransparency: false, increaseContrast: false).opacity, 1)
            XCTAssertEqual(window.swatch(for: scheme, reduceTransparency: true, increaseContrast: false).opacity, 1)
            XCTAssertEqual(window.swatch(for: scheme, reduceTransparency: false, increaseContrast: true).opacity, 1)
            let hairline = Theme.Surface.hairline
            XCTAssertGreaterThan(
                hairline.swatch(for: scheme, reduceTransparency: false, increaseContrast: true).opacity,
                hairline.swatch(for: scheme).opacity * 2, "hairlines are stronger with Increase Contrast"
            )
            // Plain colors don't change.
            XCTAssertEqual(Theme.TextColor.primary.swatch(for: scheme, reduceTransparency: true, increaseContrast: true), Theme.TextColor.primary.swatch(for: scheme))
        }
    }

    /// The notch is black with light text whatever the app's appearance (FLAS-83).
    func testNotchTokensNeverChangeWithTheTheme() {
        XCTAssertEqual(Theme.Surface.notch.light, Theme.Surface.notch.dark)
        XCTAssertEqual(Theme.Surface.notch.dark, Swatch(0x000000))
    }

    // MARK: WCAG contrast, every palette

    func testBodyTextMeetsContrastOnEverySurface() {
        for (scheme, accent) in palettes {
            for (surfaceName, surface) in surfaces(scheme, accent: accent) {
                for (textName, color) in [("primary", Theme.TextColor.primary), ("secondary", Theme.TextColor.secondary), ("cardBack", Theme.TextColor.cardBack)] {
                    assertContrast(color, on: surface, in: scheme, "\(textName) on \(surfaceName), \(accent)")
                }
            }
        }
    }

    func testAccentTextMeetsContrastOnEverySurface() {
        for (scheme, accent) in palettes {
            for (surfaceName, surface) in surfaces(scheme, accent: accent) {
                assertContrast(accent.light, on: surface, in: scheme, "\(accent) text on \(surfaceName)")
            }
        }
    }

    func testStatusColorsMeetContrastOnEverySurface() {
        for (scheme, accent) in palettes {
            for (surfaceName, surface) in surfaces(scheme, accent: accent) {
                for (name, color) in [("ok", Theme.Status.ok), ("problem", Theme.Status.problem), ("learning", Theme.Status.learning)] {
                    assertContrast(color, on: surface, in: scheme, "\(name) on \(surfaceName)")
                }
            }
        }
    }

    /// WCAG AA for the text on every accent fill (primary buttons, the selected sidebar row).
    func testWhiteTextOnEveryAccentFillMeetsAA() {
        for (scheme, accent) in palettes {
            assertContrast(Theme.TextColor.onAccent, on: accent.fill.swatch(for: scheme), in: scheme, "onAccent on \(accent) fill")
        }
    }

    /// The selected row's count and the selected search result are drawn in full white; at 85% the
    /// count dropped to 4.15:1 on indigo.
    func testTheSelectedRowTextIsNotDimmed() {
        let fill = AccentChoice.indigo.fill.dark
        let dimmed = Theme.TextColor.onAccent.dark.with(opacity: 0.85).composited(over: fill)
        XCTAssertLessThan(dimmed.contrast(with: fill), 4.5, "why it is not dimmed")
    }

    /// Text on a flipped card: the answer, its accent label and the metadata gray.
    func testTextIsLegibleOnEveryFlippedSurface() {
        for (scheme, accent) in palettes {
            let surface = accent.flippedSurface.swatch(for: scheme)
            assertContrast(Theme.TextColor.primary, on: surface, in: scheme, "primary on \(accent) flipped")
            assertContrast(Theme.TextColor.meta(isFlipped: true), on: surface, in: scheme, "meta on \(accent) flipped")
            assertContrast(accent.light, on: surface, in: scheme, "\(accent) text on its flipped surface")
        }
        XCTAssertEqual(Theme.TextColor.meta(isFlipped: false), Theme.TextColor.secondary, "unflipped keeps the design's gray")
    }

    /// Text on the translucent control fills (search field, pickers, the paste box).
    func testSecondaryTextOnControlFillsMeetsAA() {
        for (scheme, accent) in palettes {
            for (name, surface) in surfaces(scheme, accent: accent) {
                let control = Theme.Surface.control.swatch(for: scheme).composited(over: surface)
                assertContrast(Theme.TextColor.onControl, on: control, in: scheme, "onControl on a control over \(name)")
            }
        }
    }

    func testNotchTextMeetsAAOnBlack() {
        let black = Theme.Surface.notch.dark
        for opacity in [0.55, 0.62, 0.8, 1.0] {
            let text = Theme.TextColor.primary.dark.with(opacity: opacity).composited(over: black)
            XCTAssertGreaterThanOrEqual(text.contrast(with: black), 4.5, "white at \(opacity) on the notch")
        }
        XCTAssertGreaterThanOrEqual(Theme.TextColor.secondary.dark.contrast(with: black), 4.5)
    }

    /// Deck icons: a white glyph on the deck's color. Light fills reach text contrast (FLAS-81); dark
    /// keeps the graphical-object minimum (WCAG 3:1) it was designed to.
    func testWhiteGlyphOnDeckFills() {
        for (scheme, accent) in palettes {
            for color in DeckColor.allCases {
                let minimum = scheme == .light ? 4.5 : 3.0
                assertContrast(Theme.TextColor.onAccent, on: color.fill(accent: accent).swatch(for: scheme), in: scheme, atLeast: minimum, "white on deck \(color), \(accent)")
            }
        }
    }

    /// With the Orange accent, the streak flame and the orange deck color still look different from it.
    func testFlameAndOrangeDeckStayApartFromTheOrangeAccent() {
        let minimumHueDifference = 15.0
        func difference(_ a: Swatch, _ b: Swatch) -> Double {
            let d = abs(a.hue - b.hue)
            return min(d, 360 - d)
        }
        for scheme in schemes {
            let accentColors = [AccentChoice.orange.fill.swatch(for: scheme), AccentChoice.orange.light.swatch(for: scheme)]
            for other in [Theme.Streak.flame, DeckColor.orange.fill(accent: .orange)] {
                for accentColor in accentColors {
                    let d = difference(other.swatch(for: scheme), accentColor)
                    XCTAssertGreaterThanOrEqual(d, minimumHueDifference, "\(scheme): \(d)° from the accent")
                }
            }
        }
    }

    func testContrastMathMatchesKnownValues() {
        XCTAssertEqual(Swatch(0xFFFFFF).contrast(with: Swatch(0x000000)), 21, accuracy: 0.001)
        XCTAssertEqual(Swatch(0x777777).contrast(with: Swatch(0xFFFFFF)), 4.48, accuracy: 0.01)
        XCTAssertEqual(Swatch(0xFF0000).hue, 0, accuracy: 0.01)
        XCTAssertEqual(Swatch(0x00FF00).hue, 120, accuracy: 0.01)
    }

    // MARK: No hard-coded colors in views

    func testViewsUseThemeTokensInsteadOfHardCodedColors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let dirs = ["FishBrain", "FishBrainWidget", "Shared"]
        let banned = try [
            #"\bColor\s*\("#,
            #"\bColor\s*\.\s*[a-z]"#,
            #"\b(NS|UI)Color\b"#,
            #"#colorLiteral"#,
            #"0x[0-9A-Fa-f]{6}"#,
            #"\.(foregroundStyle|foregroundColor|fill|background|tint)\(\s*\.(red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|white|black|gray|primary|secondary)\b"#,
        ].map { try NSRegularExpression(pattern: $0) }

        var checked = 0
        var violations: [String] = []
        for dir in dirs {
            let base = root.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []
            for file in files where file.pathExtension == "swift" && !file.path.contains("/DesignSystem/") {
                let source = try String(contentsOf: file, encoding: .utf8)
                checked += 1
                for regex in banned {
                    let range = NSRange(source.startIndex..., in: source)
                    if let match = regex.firstMatch(in: source, range: range),
                       let r = Range(match.range, in: source) {
                        violations.append("\(file.lastPathComponent): \(source[r])")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "lint found no source files; check the path logic")
        XCTAssertEqual(violations, [], "Hard-coded colors found; use Theme tokens")
    }
}

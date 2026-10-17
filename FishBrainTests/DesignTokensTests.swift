import XCTest

final class DesignTokensTests: XCTestCase {
    /// The darkest possible backdrop; translucent surfaces get lighter over anything brighter,
    /// so contrast is checked against the surfaces as they look over black (the intended look).
    private let backdrop = Token(0x000000)

    private var windowOpaque: Token { Theme.Surface.window.composited(over: backdrop) }
    private var surfaces: [(name: String, token: Token)] {
        [
            ("window", windowOpaque),
            ("sidebar", Theme.Surface.sidebar.composited(over: windowOpaque)),
            ("group", Theme.Surface.group.composited(over: windowOpaque)),
        ]
    }

    // MARK: Spec values

    func testSurfaceValuesMatchTheDesign() {
        XCTAssertEqual(Theme.Surface.window, Token(0x16161A, opacity: 0.82))
        XCTAssertEqual(Theme.Surface.sidebar, Token(0x28282E, opacity: 0.60))
        XCTAssertEqual(Theme.Surface.group, Token(0x2C2C32, opacity: 0.70))
        XCTAssertEqual(Theme.Surface.hairline, Token(0xFFFFFF, opacity: 0.08))
    }

    func testTextAndAccentValuesMatchTheDesign() {
        XCTAssertEqual(Theme.TextColor.primary, Token(0xFFFFFF))
        XCTAssertEqual(Theme.TextColor.secondary, Token(0x8D8D93))
        XCTAssertEqual(Theme.TextColor.cardBack, Token(0xC7C7CC))
        XCTAssertEqual(AccentChoice.default, .indigo)
        XCTAssertEqual(AccentChoice.indigo.fill, Token(0x5E5CE6))
        XCTAssertEqual(AccentChoice.indigo.light, Token(0xA5A3FF))
        XCTAssertEqual(AccentChoice.blue.fill, Token(0x0A6CDB))
        // Purple and teal are the canvas colors darkened just enough for white text to reach 4.5:1.
        XCTAssertEqual(AccentChoice.purple.fill, Token(0xA54ED5))
        XCTAssertEqual(AccentChoice.teal.fill, Token(0x168195))
        XCTAssertEqual(AccentChoice.indigo.flippedSurface, Token(0x26254A))
        XCTAssertEqual(DeckColor.green.fill(accent: .indigo), Token(0x248A3D))
        XCTAssertEqual(DeckColor.purple.fill(accent: .indigo), Token(0xA64FD6))
        XCTAssertEqual(DeckColor.orange.fill(accent: .indigo), Token(0xC96A00))
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

    // MARK: WCAG contrast

    func testBodyTextMeetsContrastOnEverySurface() {
        let text = [
            ("primary", Theme.TextColor.primary),
            ("secondary", Theme.TextColor.secondary),
            ("cardBack", Theme.TextColor.cardBack),
        ]
        for (textName, color) in text {
            for (surfaceName, surface) in surfaces {
                let ratio = color.contrast(with: surface)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(textName) on \(surfaceName): \(ratio)")
            }
        }
    }

    func testAccentTextMeetsContrastOnEverySurface() {
        for accent in AccentChoice.allCases {
            for (surfaceName, surface) in surfaces {
                let ratio = accent.light.contrast(with: surface)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(accent) light on \(surfaceName): \(ratio)")
            }
        }
    }

    /// WCAG AA for the text on every accent fill (primary buttons, the selected sidebar row).
    func testWhiteTextOnEveryAccentFillMeetsAA() {
        for accent in AccentChoice.allCases {
            let ratio = Theme.TextColor.primary.contrast(with: accent.fill)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "white on \(accent) fill: \(ratio)")
        }
    }

    /// The selected row's count and the selected search result are drawn in full white; at 85% the
    /// count dropped to 4.15:1 on indigo.
    func testTheSelectedRowTextIsLegibleOnTheAccentFill() {
        let dimmed = Theme.TextColor.primary.with(opacity: 0.85).composited(over: AccentChoice.indigo.fill)
        XCTAssertLessThan(dimmed.contrast(with: AccentChoice.indigo.fill), 4.5, "why it is not dimmed")
        for accent in AccentChoice.allCases {
            XCTAssertGreaterThanOrEqual(Theme.TextColor.primary.contrast(with: accent.fill), 4.5)
        }
    }

    /// Metadata on a flipped card's tinted surface uses the lighter gray; `secondary` fell to 3.7-4.4.
    func testMetadataIsLegibleOnEveryFlippedSurface() {
        for accent in AccentChoice.allCases {
            let surface = accent.flippedSurface
            let meta = Theme.TextColor.meta(isFlipped: true)
            XCTAssertGreaterThanOrEqual(meta.contrast(with: surface), 4.5, "meta on \(accent) flipped: \(meta.contrast(with: surface))")
        }
        XCTAssertEqual(Theme.TextColor.meta(isFlipped: false), Theme.TextColor.secondary, "unflipped keeps the design's gray")
    }

    /// Text on the translucent control fills (search field, pickers, the paste box).
    func testSecondaryTextOnControlFillsMeetsAA() {
        for (name, surface) in surfaces {
            let control = Theme.Surface.control.composited(over: surface)
            let ratio = Theme.TextColor.onControl.contrast(with: control)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "onControl on a control over \(name): \(ratio)")
        }
    }

    func testTheDesignsSecondaryGrayStillPassesWhereItIsUsedOnPlainSurfaces() {
        for (name, surface) in surfaces {
            XCTAssertGreaterThanOrEqual(Theme.TextColor.secondary.contrast(with: surface), 4.5, name)
        }
    }

    func testNotchTextMeetsAAOnBlack() {
        let black = Theme.Surface.notch
        for opacity in [0.55, 0.62, 0.8, 1.0] {
            let text = Theme.TextColor.primary.with(opacity: opacity).composited(over: black)
            XCTAssertGreaterThanOrEqual(text.contrast(with: black), 4.5, "white at \(opacity) on the notch")
        }
        XCTAssertGreaterThanOrEqual(Theme.TextColor.secondary.contrast(with: black), 4.5)
    }

    func testAnswerLabelAndTextMeetContrastOnFlippedSurface() {
        for accent in AccentChoice.allCases {
            let surface = accent.flippedSurface
            XCTAssertGreaterThanOrEqual(Theme.TextColor.primary.contrast(with: surface), 4.5, "\(accent)")
            XCTAssertGreaterThanOrEqual(accent.light.contrast(with: surface), 4.5, "\(accent)")
        }
    }

    /// Deck colors fill icons (graphical objects, WCAG 3:1), not body text.
    func testWhiteGlyphOnDeckFillMeetsGraphicalContrast() {
        for color in DeckColor.allCases {
            for accent in AccentChoice.allCases {
                let ratio = Theme.TextColor.primary.contrast(with: color.fill(accent: accent))
                XCTAssertGreaterThanOrEqual(ratio, 3.0, "white on \(color)/\(accent): \(ratio)")
            }
        }
    }

    func testContrastMathMatchesKnownValues() {
        XCTAssertEqual(Token(0xFFFFFF).contrast(with: Token(0x000000)), 21, accuracy: 0.001)
        XCTAssertEqual(Token(0x777777).contrast(with: Token(0xFFFFFF)), 4.48, accuracy: 0.01)
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

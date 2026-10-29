import SwiftUI

/// The FishBrain design system. Every color, material, font size and radius used by the app, widget
/// and notch comes from here; views must not define their own. Each color has a dark value (the
/// original "Frosted Midnight" design) and a light one ("Tangerine and white", tinted by the accent).
enum Theme {
    /// Surfaces are translucent glass: smoked in dark, near-white in light.
    enum Surface {
        static let window = Token(dark: Swatch(0x16161A, opacity: 0.82), light: Swatch(0xFFFFFF, opacity: 0.94), role: .glass)
        /// The sidebar in dark. In light the sidebar is tinted by the accent: use `AccentChoice.sidebar`.
        static let sidebar = Token(0x28282E, opacity: 0.60, role: .glass)
        static let group = Token(dark: Swatch(0x2C2C32, opacity: 0.70), light: Swatch(0xFFFFFF, opacity: 0.90), role: .glass)
        static let hairline = Token(dark: Swatch(0xFFFFFF, opacity: 0.08), light: Swatch(0x1F1A17, opacity: 0.12), role: .line)
        /// Widget surface (translucent, over the system widget material).
        static let widget = Token(dark: Swatch(0x28282E, opacity: 0.82), light: Swatch(0xFFFFFF, opacity: 0.94), role: .glass)
        /// Tinted-gray fill for secondary controls and fields.
        static let control = Token(dark: Swatch(0x767680, opacity: 0.24), light: Swatch(0x767680, opacity: 0.12))
        static let progressTrack = Token(dark: Swatch(0xFFFFFF, opacity: 0.12), light: Swatch(0x1F1A17, opacity: 0.10), role: .line)
        /// The chosen segment of a segmented control, on top of `control`.
        static let segmentSelected = Token(dark: 0x636366, light: 0xFFFFFF)
        /// Icon backdrop on top of an accent-filled row (white glyph, so the same in both).
        static let onAccentIcon = Token(0xFFFFFF, opacity: 0.22)
        /// A switch that is on.
        static let switchOn = Token(dark: 0x30D158, light: 0x34C759)
        /// The notch display: pure black in every appearance, so it merges with the hardware notch.
        static let notch = Token(0x000000)
        /// Neutral desktop-like backdrop for previews and the component gallery only.
        static let previewBackdrop = Token(dark: 0x23262E, light: 0xECE8E4)
    }

    /// Blur layers that sit under the matching `Surface` tint. Materials follow the appearance.
    enum Blur {
        static let window: Material = .ultraThinMaterial
        static let sidebar: Material = .thinMaterial
        static let group: Material = .ultraThinMaterial
    }

    /// A check that passed, and one that didn't. Light values are darkened to read on white.
    enum Status {
        static let ok = Token(dark: 0x30D158, light: 0x186E2F)
        static let problem = Token(dark: 0xFF6B61, light: 0xC0301F)
        /// A card still being learned.
        static let learning = Token(dark: 0xFFB340, light: 0x8F5600)
    }

    /// Study streak: the flame and the week's dots. Gold rather than orange, so it never looks like the
    /// Orange accent.
    enum Streak {
        static let flame = Token(dark: 0xFFC233, light: 0xA86E00)
    }

    enum TextColor {
        static let primary = Token(dark: 0xFFFFFF, light: 0x1F1A17)
        static let secondary = Token(dark: 0x8D8D93, light: 0x6E655E)
        static let cardBack = Token(dark: 0xC7C7CC, light: 0x4A423C)
        /// Secondary text on the translucent control fills (search field, pickers), where
        /// `secondary` falls just short of 4.5:1.
        static let onControl = Token(dark: 0xA1A1A7, light: 0x5C544E)
        /// Text and glyphs on an accent or deck-color fill (primary buttons, the selected row, deck icons):
        /// white in both appearances.
        static let onAccent = Token(0xFFFFFF)

        /// Metadata text (deck name, position, countdown). On a flipped card's tinted surface
        /// `secondary` is too dim (3.7 to 4.4:1 in dark), so the card-back gray is used there.
        static func meta(isFlipped: Bool) -> Token { isFlipped ? cardBack : secondary }
    }

    /// Sizes from the design; weights are SF system.
    enum Typography {
        static let title = Font.system(size: 30, weight: .bold)
        static let body = Font.system(size: 15)
        static let rowTitle = Font.system(size: 14)
        static let sectionLabel = Font.system(size: 11, weight: .semibold)
        static let caption = Font.system(size: 13)
        static let footnote = Font.system(size: 12)
        static let micro = Font.system(size: 11)
    }

    /// Capsule buttons are fully rounded: use `Capsule()` rather than a radius.
    enum Radius {
        static let window: CGFloat = 16
        static let group: CGFloat = 14
        static let widget: CGFloat = 22
    }
}

/// The user-selectable accent, with values from the design canvas. `fill` is for backgrounds; `light`
/// is for accent-colored text and progress. In light both are the same deep value; in dark `light` is
/// a lighter tint that reads on the dark glass.
enum AccentChoice: String, Codable, CaseIterable, Sendable {
    // The order is the order of the swatches in Settings.
    case orange, indigo, blue, purple, teal

    static let `default` = AccentChoice.orange

    /// Unknown values (e.g. written by a newer version) decode as the default.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AccentChoice(rawValue: raw) ?? .default
    }

    var displayName: String { rawValue.capitalized }

    var fill: Token {
        switch self {
        case .orange: Token(dark: 0xC2410C, light: 0xC2410C)
        case .indigo: Token(dark: 0x5E5CE6, light: 0x4F4CD8)
        case .blue: Token(dark: 0x0A6CDB, light: 0x0A66D6)
        case .purple: Token(dark: 0xA54ED5, light: 0x8E3CC2)
        case .teal: Token(dark: 0x168195, light: 0x0F766E)
        }
    }

    /// Accent-colored text, progress and marks.
    var light: Token {
        switch self {
        case .orange: Token(dark: 0xFFA36B, light: 0xC2410C)
        case .indigo: Token(dark: 0xA5A3FF, light: 0x4F4CD8)
        case .blue: Token(dark: 0x70B7FF, light: 0x0A66D6)
        case .purple: Token(dark: 0xDA9BF8, light: 0x8E3CC2)
        case .teal: Token(dark: 0x7FDCEB, light: 0x0F766E)
        }
    }

    /// Accent-tinted background for a flipped (answer) card, tinted buttons and chips.
    var flippedSurface: Token {
        switch self {
        case .orange: Token(dark: 0x3D2418, light: 0xFFF1E7)
        case .indigo: Token(dark: 0x26254A, light: 0xEDEDFB)
        case .blue: Token(dark: 0x18304D, light: 0xE8F1FC)
        case .purple: Token(dark: 0x3A2448, light: 0xF3E9FA)
        case .teal: Token(dark: 0x173A40, light: 0xE4F3F1)
        }
    }

    /// The sidebar: the shared smoked glass in dark, a pale tint of the accent in light.
    var sidebar: Token {
        let tint: UInt32 = switch self {
        case .orange: 0xFFF4EC
        case .indigo: 0xF4F4FB
        case .blue: 0xF1F6FD
        case .purple: 0xF7F1FB
        case .teal: 0xEEF7F6
        }
        return Token(dark: Theme.Surface.sidebar.dark, light: Swatch(tint, opacity: 0.94), role: .glass)
    }
}

extension DeckColor {
    /// Fill for a deck's icon, under a white glyph. `.accent` follows the user's accent choice. Orange is
    /// a deep amber, so it stays apart from the Orange accent.
    func fill(accent: AccentChoice) -> Token {
        switch self {
        case .accent: accent.fill
        case .green: Token(dark: 0x248A3D, light: 0x1F7A36)
        case .purple: Token(dark: 0xA64FD6, light: 0x8E44C0)
        case .orange: Token(dark: 0xB87400, light: 0x9C6200)
        }
    }
}

import SwiftUI

/// The Frosted Midnight design system. Every color, material, font size and radius used by the
/// app, widget and notch comes from here; views must not define their own.
enum Theme {
    /// Dark-only design: surfaces are translucent smoked glass.
    enum Surface {
        static let window = Token(0x16161A, opacity: 0.82)
        static let sidebar = Token(0x28282E, opacity: 0.60)
        static let group = Token(0x2C2C32, opacity: 0.70)
        static let hairline = Token(0xFFFFFF, opacity: 0.08)
        /// Widget surface (translucent, over the system widget material).
        static let widget = Token(0x28282E, opacity: 0.82)
        /// Tinted-gray fill for secondary controls and fields.
        static let control = Token(0x767680, opacity: 0.24)
        static let progressTrack = Token(0xFFFFFF, opacity: 0.12)
        /// The chosen segment of a segmented control, on top of `control`.
        static let segmentSelected = Token(0x636366)
        /// Icon backdrop on top of an accent-filled row.
        static let onAccentIcon = Token(0xFFFFFF, opacity: 0.22)
        /// A switch that is on.
        static let switchOn = Token(0x30D158)
        /// The notch display: pure black, so it merges with the hardware notch.
        static let notch = Token(0x000000)
        /// Neutral desktop-like backdrop for previews and the component gallery only.
        static let previewBackdrop = Token(0x23262E)
    }

    /// Blur layers that sit under the matching `Surface` tint.
    enum Blur {
        static let window: Material = .ultraThinMaterial
        static let sidebar: Material = .thinMaterial
        static let group: Material = .ultraThinMaterial
    }

    /// A check that passed, and one that didn't.
    enum Status {
        static let ok = Token(0x30D158)
        static let problem = Token(0xFF6B61)
        /// A card still being learned.
        static let learning = Token(0xFFB340)
    }

    /// Study streak: the one warm color in an otherwise cool app (the flame and the week's dots).
    enum Streak {
        static let flame = Token(0xFF7A2F)
    }

    enum TextColor {
        static let primary = Token(0xFFFFFF)
        static let secondary = Token(0x8D8D93)
        static let cardBack = Token(0xC7C7CC)
        /// Secondary text on the translucent control fills (search field, pickers), where
        /// `secondary` falls just short of 4.5:1.
        static let onControl = Token(0xA1A1A7)

        /// Metadata text (deck name, position, countdown). On a flipped card's tinted surface
        /// `secondary` is too dim (3.7 to 4.4:1), so the lighter card-back gray is used there.
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

/// The user-selectable accent, with values from the design canvas. `fill` is for backgrounds;
/// `light` is for accent-colored text and progress on dark surfaces.
enum AccentChoice: String, Codable, CaseIterable, Sendable {
    case indigo, blue, purple, teal

    static let `default` = AccentChoice.indigo

    /// Unknown values (e.g. written by a newer version) decode as the default.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AccentChoice(rawValue: raw) ?? .default
    }

    var displayName: String { rawValue.capitalized }

    var fill: Token {
        switch self {
        case .indigo: Token(0x5E5CE6)
        case .blue: Token(0x0A6CDB)
        case .purple: Token(0xA54ED5)
        case .teal: Token(0x168195)
        }
    }

    var light: Token {
        switch self {
        case .indigo: Token(0xA5A3FF)
        case .blue: Token(0x70B7FF)
        case .purple: Token(0xDA9BF8)
        case .teal: Token(0x7FDCEB)
        }
    }

    /// Accent-tinted background for a flipped (answer) card.
    var flippedSurface: Token {
        switch self {
        case .indigo: Token(0x26254A)
        case .blue: Token(0x18304D)
        case .purple: Token(0x3A2448)
        case .teal: Token(0x173A40)
        }
    }
}

extension DeckColor {
    /// Dark-safe fill for a deck's icon. `.accent` follows the user's accent choice.
    func fill(accent: AccentChoice) -> Token {
        switch self {
        case .accent: accent.fill
        case .green: Token(0x248A3D)
        case .purple: Token(0xA64FD6)
        case .orange: Token(0xC96A00)
        }
    }
}

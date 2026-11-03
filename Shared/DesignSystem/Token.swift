import AppKit
import SwiftUI

/// One fixed sRGB color, as drawn in one appearance. Components are in 0...1. This is what contrast
/// checks work on; views use `Token`, which picks the swatch for the appearance in use.
struct Swatch: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(_ hex: UInt32, opacity: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.opacity = opacity
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }

    func with(opacity: Double) -> Swatch {
        var copy = self
        copy.opacity = opacity
        return copy
    }

    /// The opaque color this swatch produces when drawn over `background`.
    func composited(over background: Swatch) -> Swatch {
        func mix(_ fg: Double, _ bg: Double) -> Double { fg * opacity + bg * (1 - opacity) }
        var result = self
        result.red = mix(red, background.red)
        result.green = mix(green, background.green)
        result.blue = mix(blue, background.blue)
        result.opacity = 1
        return result
    }

    /// WCAG 2.x relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio (1...21) between two opaque swatches.
    func contrast(with other: Swatch) -> Double {
        let (lighter, darker) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Hue in degrees (0..<360), for telling colors of similar lightness apart.
    var hue: Double {
        let maxC = max(red, green, blue), minC = min(red, green, blue), delta = maxC - minC
        guard delta > 0 else { return 0 }
        let h: Double
        if maxC == red {
            h = (green - blue) / delta
        } else if maxC == green {
            h = (blue - red) / delta + 2
        } else {
            h = (red - green) / delta + 4
        }
        return (h * 60 + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// A design color with a value for dark and one for light. It is a SwiftUI style, so
/// `.foregroundStyle(token)` and `.fill(token)` pick the right value from the environment's color
/// scheme without the view knowing which appearance is on.
struct Token: ShapeStyle, Hashable, Sendable {
    /// How the token reacts to the accessibility display settings.
    enum Role: Hashable, Sendable {
        case plain
        /// A translucent surface tint over a blur: solid with Reduce Transparency or Increase Contrast.
        case glass
        /// A hairline or track: three times as strong with Increase Contrast.
        case line
    }

    var dark: Swatch
    var light: Swatch
    var role: Role

    /// The same color in both appearances.
    init(_ hex: UInt32, opacity: Double = 1, role: Role = .plain) {
        dark = Swatch(hex, opacity: opacity)
        light = dark
        self.role = role
    }

    init(dark: UInt32, light: UInt32, opacity: Double = 1, role: Role = .plain) {
        self.init(dark: Swatch(dark, opacity: opacity), light: Swatch(light, opacity: opacity), role: role)
    }

    init(dark: Swatch, light: Swatch, role: Role = .plain) {
        self.dark = dark
        self.light = light
        self.role = role
    }

    /// The design value for an appearance.
    func swatch(for scheme: ColorScheme) -> Swatch {
        scheme == .light ? light : dark
    }

    /// The value drawn, after the accessibility display settings.
    func swatch(for scheme: ColorScheme, reduceTransparency: Bool, increaseContrast: Bool) -> Swatch {
        let base = swatch(for: scheme)
        switch role {
        case .plain:
            return base
        case .glass:
            return reduceTransparency || increaseContrast ? base.with(opacity: 1) : base
        case .line:
            return increaseContrast ? base.with(opacity: min(base.opacity * 3, 1)) : base
        }
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        swatch(
            for: environment.colorScheme,
            reduceTransparency: environment.accessibilityReduceTransparency,
            increaseContrast: environment.colorSchemeContrast == .increased
        ).color
    }

    /// For APIs that take a `Color` (`.tint`, `.shadow`). It follows the appearance of whatever it is
    /// drawn in, like the token itself.
    var color: Color {
        if dark == light && role == .plain { return dark.color }
        let token = self
        return Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let isHighContrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            return token.swatch(
                for: isDark ? .dark : .light,
                reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                increaseContrast: isHighContrast
            ).nsColor
        })
    }

    /// Both values at a new opacity.
    func with(opacity: Double) -> Token {
        Token(dark: dark.with(opacity: opacity), light: light.with(opacity: opacity), role: role)
    }
}

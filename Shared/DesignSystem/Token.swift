import SwiftUI

/// A color value that can be used directly as a SwiftUI style (`.foregroundStyle(token)`) and
/// inspected numerically (contrast checks). Components are sRGB in 0...1.
struct Token: ShapeStyle, Hashable, Sendable {
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

    func with(opacity: Double) -> Token {
        var copy = self
        copy.opacity = opacity
        return copy
    }

    func resolve(in environment: EnvironmentValues) -> Color { color }

    /// The opaque color this token produces when drawn over `background`.
    func composited(over background: Token) -> Token {
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

    /// WCAG contrast ratio (1...21) between two opaque tokens.
    func contrast(with other: Token) -> Double {
        let (lighter, darker) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (lighter + 0.05) / (darker + 0.05)
    }
}

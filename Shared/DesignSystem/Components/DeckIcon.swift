import SwiftUI

/// The card-stack glyph, drawn on a 24-unit grid.
struct StackGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: rect.minX + 4 * unit, y: rect.minY + 8 * unit, width: 16 * unit, height: 12 * unit),
            cornerSize: CGSize(width: 2 * unit, height: 2 * unit)
        )
        path.move(to: point(7, 4.5))
        path.addLine(to: point(17, 4.5))
        return path
    }
}

/// Rounded square in the deck's color with the stack glyph. `isOnAccent` swaps the fill for a
/// translucent white so the icon stays visible on an accent-filled row.
struct DeckIcon: View {
    var color: DeckColor
    var size: CGFloat = 22
    var isOnAccent = false

    @Environment(\.accentChoice) private var accent

    var body: some View {
        let glyph = size * 13 / 22
        RoundedRectangle(cornerRadius: size * 6 / 22, style: .continuous)
            .fill(isOnAccent ? Theme.Surface.onAccentIcon : color.fill(accent: accent))
            .frame(width: size, height: size)
            .overlay {
                StackGlyph()
                    .stroke(Theme.TextColor.primary, style: StrokeStyle(lineWidth: glyph * 2.4 / 24, lineCap: .round))
                    .frame(width: glyph, height: glyph)
            }
            .accessibilityHidden(true)
    }
}

#Preview("DeckIcon") {
    HStack(spacing: 12) {
        ForEach(DeckColor.allCases, id: \.self) { DeckIcon(color: $0, size: 32) }
        DeckIcon(color: .accent, size: 32, isOnAccent: true)
    }
    .padding(24)
    .background(Theme.Surface.previewBackdrop)
}

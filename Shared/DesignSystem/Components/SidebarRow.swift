import SwiftUI

/// A deck in the sidebar. The selected row is filled with the accent.
struct SidebarRow: View {
    var name: String
    var count: Int
    var color: DeckColor
    var isSelected = false
    /// Chosen along with other rows: a lighter fill than the open one.
    var isPicked = false

    @Environment(\.accentChoice) private var accent

    /// "Everyday Spanish, 48 cards": what VoiceOver says for the row.
    static func accessibilityText(name: String, count: Int) -> String {
        "\(name), \(count) \(count == 1 ? "card" : "cards")"
    }

    var body: some View {
        HStack(spacing: 10) {
            DeckIcon(color: color, size: 22, isOnAccent: isSelected)
            Text(name)
                .font(Theme.Typography.rowTitle.weight(isSelected ? .medium : .regular))
                .foregroundStyle(Theme.TextColor.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(count)")
                .font(Theme.Typography.caption)
                .foregroundStyle(isSelected ? Theme.TextColor.primary : Theme.TextColor.secondary)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.fill)
            } else if isPicked {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.fill.with(opacity: 0.4))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(name: name, count: count))
        .accessibilityAddTraits(isSelected || isPicked ? .isSelected : [])
    }
}

#Preview("SidebarRow") {
    VStack(spacing: 2) {
        SidebarRow(name: "Everyday Spanish", count: 48, color: .accent, isSelected: true)
        SidebarRow(name: "Biology 101", count: 32, color: .green)
        SidebarRow(name: "Swift Interview", count: 20, color: .purple)
        SidebarRow(name: "World Capitals", count: 60, color: .orange)
    }
    .frame(width: 240)
    .padding(12)
    .background(Theme.Surface.previewBackdrop)
}

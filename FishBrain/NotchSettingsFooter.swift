import SwiftUI

/// "Show in notch" and which deck the notch studies, at the bottom of the sidebar.
struct NotchSettingsFooter: View {
    var decks: [Deck]
    /// For the section titles of the picker; with none, the decks are listed flat.
    var subjects: [Subject] = []

    @EnvironmentObject private var settings: SettingsStore

    /// The deck the notch currently shows: the chosen one, or the first deck.
    private var shownDeck: Deck? {
        DeckSelection.resolve(settings.notchDeckID, in: decks)
    }

    @ViewBuilder
    private func deckButtons(_ decks: [Deck]) -> some View {
        ForEach(decks) { deck in
            Button {
                settings.notchDeckID = deck.id
            } label: {
                if deck.id == shownDeck?.id {
                    Label(deck.name, systemImage: "checkmark")
                } else {
                    Text(deck.name)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Show in notch")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.TextColor.primary)
                Spacer(minLength: 8)
                Toggle("Show in notch", isOn: $settings.showsNotch)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.Surface.switchOn.color)
                    .accessibilityLabel("Show in notch")
            }

            Menu {
                ForEach(Array(DeckPicker.sections(decks: decks, subjects: subjects).enumerated()), id: \.offset) { _, section in
                    if let title = section.title {
                        Section(title) { deckButtons(section.decks) }
                    } else {
                        deckButtons(section.decks)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(shownDeck?.name ?? "No decks")
                        .lineLimit(1)
                        .foregroundStyle(Theme.TextColor.primary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.TextColor.onControl)
                        .accessibilityHidden(true)
                }
                .font(Theme.Typography.caption)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.Surface.control))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(decks.isEmpty || !settings.showsNotch)
            .opacity(settings.showsNotch ? 1 : 0.5)
            .accessibilityLabel("Notch deck")
            .accessibilityValue(shownDeck?.name ?? "None")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.TextColor.primary.with(opacity: 0.06)))
    }
}

#if DEBUG
#Preview("Notch settings") {
    NotchSettingsFooter(decks: PreviewData.decks)
        .environmentObject(PreviewData.settings())
        .frame(width: 216)
        .appearancePreview()
}
#endif

import SwiftUI

/// "Show in notch" and which deck the notch studies, at the bottom of the sidebar.
struct NotchSettingsFooter: View {
    var decks: [Deck]
    /// For the section titles of the picker; with none, the decks are listed flat.
    var subjects: [Subject] = []
    /// The deck of the notch study session that is running, if any: the notch keeps it until the session
    /// ends, so a different choice here reads "After this session: …".
    var sessionDeckID: Deck.ID?

    @EnvironmentObject private var settings: SettingsStore

    /// The deck chosen for the notch, or the first deck. During a session the notch shows the session's.
    private var shownDeck: Deck? {
        DeckSelection.resolve(settings.notchDeckID, in: decks)
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
                NotchDeckMenu(
                    sections: NotchDeckMenuModel.sections(decks: decks, subjects: subjects),
                    currentID: shownDeck?.id,
                    onChoose: { settings.notchDeckID = $0 }
                )
            } label: {
                HStack(spacing: 6) {
                    Text(NotchDeckMenuModel.footerLabel(chosen: shownDeck, sessionDeckID: sessionDeckID))
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
            .accessibilityLabel(NotchDeckMenuModel.accessibilityLabel)
            .accessibilityValue(NotchDeckMenuModel.footerLabel(chosen: shownDeck, sessionDeckID: sessionDeckID))
            .accessibilityHint(NotchDeckMenuModel.hint)
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

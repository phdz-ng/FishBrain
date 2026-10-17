import SwiftUI

/// Paste a list of cards, see how many were found, and add them all at once.
struct PasteCardsSheet: View {
    var deckName: String
    var onAdd: ([ParsedCard]) -> Void
    var onCancel: () -> Void

    @State private var text = ""
    @FocusState private var isEditorFocused: Bool
    @Environment(\.accentChoice) private var accent

    private static let example = "hola, hello\n\"hola, amigo\", \"hello, friend\"\nla mesa\tthe table"

    var body: some View {
        let result = CardParser.parse(text)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Paste Cards")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.TextColor.primary)
                Text("One card per line. Separate the front and back with a comma or a tab, and use quotes around text that contains commas. Added to “\(deckName)”.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.TextColor.primary)
                .scrollContentBackground(.hidden)
                .focused($isEditorFocused)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.Surface.control))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(Self.example)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.TextColor.onControl)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Cards to paste")

            HStack {
                Text(summary(for: result))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(result.cards.isEmpty ? Theme.TextColor.secondary : accent.light)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.capsuleSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(addTitle(for: result)) { onAdd(result.cards) }
                    .buttonStyle(.capsulePrimary)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(result.cards.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520, height: 420)
        .background {
            ZStack {
                Rectangle().fill(Theme.Blur.window)
                Rectangle().fill(Theme.Surface.window)
            }
        }
        .onAppear { isEditorFocused = true }
    }

    private func summary(for result: CardParseResult) -> String {
        PasteSummary.text(found: result.cards.count, skipped: result.skippedLines)
    }

    private func addTitle(for result: CardParseResult) -> String {
        switch result.cards.count {
        case 0: "Add"
        case 1: "Add 1 Card"
        default: "Add \(result.cards.count) Cards"
        }
    }
}

#if DEBUG
#Preview("Paste Cards") {
    PasteCardsSheet(deckName: "Everyday Spanish", onAdd: { _ in }, onCancel: {})
        .preferredColorScheme(.dark)
}
#endif

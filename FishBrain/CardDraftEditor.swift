import SwiftUI

/// The small editor in the open notch for a card made from a copy: Front (filled in with what was
/// copied), Back (where the cursor starts), the deck, and Save and Cancel. Return saves, Escape cancels.
struct CardDraftEditor: View {
    @ObservedObject var model: NotchModel

    private enum Field { case front, back }
    @FocusState private var focus: Field?

    private var draft: Binding<CardDraft> {
        Binding(get: { model.cardDraft ?? CardDraft(front: "") }, set: { model.cardDraft = $0 })
    }

    private var deckName: String {
        model.deckChoices.first { $0.id == model.cardDraft?.deckID }?.name ?? "Choose a deck"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("New card")
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.62))
                Spacer(minLength: 8)
                Menu {
                    ForEach(model.deckChoices) { choice in
                        Button(choice.name) { model.cardDraft?.deckID = choice.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(deckName).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.TextColor.primary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Theme.TextColor.primary.with(opacity: 0.16)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Deck, \(deckName)")
            }

            field("Front", text: draft.front, focus: .front)
            field("Back", text: draft.back, focus: .back)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: model.onCancelDraft)
                    .buttonStyle(.plain)
                    .font(Theme.Typography.micro.weight(.semibold))
                    .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.7))
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .accessibilityHint("Escape")
                Button("Save", action: model.onSaveDraft)
                    .buttonStyle(.plain)
                    .font(Theme.Typography.micro.weight(.semibold))
                    .foregroundStyle(Theme.TextColor.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.TextColor.primary.with(opacity: 0.2)))
                    .disabled(draft.wrappedValue.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Return")
            }
        }
        // Escape closes it without saving.
        .onExitCommand(perform: model.onCancelDraft)
        // The cursor starts in the Back, since the Front is what was copied. A moment later, so the
        // field exists to take it.
        .onAppear { DispatchQueue.main.async { focus = .back } }
    }

    private func field(_ title: String, text: Binding<String>, focus field: Field) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.TextColor.primary)
            .focused($focus, equals: field)
            .onSubmit(model.onSaveDraft)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.TextColor.primary.with(opacity: 0.09)))
            .accessibilityLabel(title)
    }
}

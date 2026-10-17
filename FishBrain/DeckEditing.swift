import AppKit
import SwiftUI

/// The deck title; click to rename it in place. Return or clicking away saves, Esc cancels.
struct EditableTitle: View {
    var text: String
    @Binding var isEditing: Bool
    var onCommit: (String) -> Void
    /// What the empty field and VoiceOver call the name: a deck's, or a subject's.
    var placeholder = "Deck name"
    var hint = "Renames the deck"

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.Typography.title)
                .tracking(-0.4)
                .foregroundStyle(Theme.TextColor.primary)
                .frame(minWidth: 240, alignment: .leading)
                .focused($isFocused)
                .onSubmit(commit)
                .onExitCommand { isEditing = false }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onAppear {
                    draft = text
                    isFocused = true
                    // Start with the whole name selected so typing replaces it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                }
        } else {
            Text(text)
                .font(Theme.Typography.title)
                .tracking(-0.4)
                .foregroundStyle(Theme.TextColor.primary)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { isEditing = true }
                .help("Click to rename")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(hint)
        }
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        onCommit(draft)
    }
}

/// Row of the dark-safe deck colors.
struct DeckColorPicker: View {
    var selection: DeckColor
    var onSelect: (DeckColor) -> Void

    @Environment(\.accentChoice) private var accent

    var body: some View {
        HStack(spacing: 14) {
            ForEach(DeckColor.allCases, id: \.self) { color in
                let isSelected = color == selection
                Button { onSelect(color) } label: {
                    VStack(spacing: 6) {
                        DeckIcon(color: color, size: 28)
                            .padding(3)
                            .overlay {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Theme.TextColor.primary, lineWidth: 2)
                                }
                            }
                        Text(color.displayName)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(isSelected ? Theme.TextColor.primary : Theme.TextColor.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.displayName)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(16)
    }
}

/// "New Deck" at the end of the sidebar list.
struct NewDeckButton: View {
    var action: () -> Void

    @Environment(\.accentChoice) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(Theme.Typography.rowTitle.weight(.semibold))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text("New Deck")
                    .font(Theme.Typography.rowTitle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(accent.light)
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Deck editing") {
    VStack(alignment: .leading, spacing: 20) {
        EditableTitle(text: "Everyday Spanish", isEditing: .constant(false)) { _ in }
        EditableTitle(text: "Everyday Spanish", isEditing: .constant(true)) { _ in }
        DeckColorPicker(selection: .green) { _ in }
        NewDeckButton {}.frame(width: 200)
    }
    .padding(24)
    .background(Theme.Surface.previewBackdrop)
}

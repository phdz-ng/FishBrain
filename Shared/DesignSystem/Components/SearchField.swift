import SwiftUI

/// Rounded search field with a magnifier and a clear button. Esc clears it.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.TextColor.onControl)
                .accessibilityHidden(true)
            TextField(text: $text, prompt: Text(prompt).foregroundStyle(Theme.TextColor.onControl)) {
                Text(prompt)
            }
                .textFieldStyle(.plain)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.TextColor.primary)
                .focused(isFocused)
                .onSubmit(onSubmit)
                .onExitCommand { text = "" }
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.TextColor.onControl)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.Surface.control))
    }
}

#Preview("SearchField") {
    struct Demo: View {
        @State var text = "sobre"
        @FocusState var focused: Bool
        var body: some View {
            SearchField(text: $text, prompt: "Search cards", isFocused: $focused)
                .frame(width: 216)
                .appearancePreview()
        }
    }
    return Demo()
}

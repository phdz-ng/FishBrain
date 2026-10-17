import SwiftUI

/// Fully rounded buttons: filled accent (primary), tinted gray (secondary), and the accent's soft tint (for
/// a button that starts something with AI, next to the gray ones).
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, tinted }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(kind: kind, configuration: configuration)
    }

    private struct StyledLabel: View {
        var kind: Kind
        var configuration: Configuration
        @Environment(\.accentChoice) private var accent

        private var fill: Token {
            switch kind {
            case .primary: accent.fill
            case .secondary: Theme.Surface.control
            case .tinted: accent.flippedSurface
            }
        }

        var body: some View {
            configuration.label
                .font(Theme.Typography.caption.weight(kind == .primary ? .semibold : .medium))
                .foregroundStyle(kind == .tinted ? accent.light : Theme.TextColor.primary)
                .padding(.horizontal, kind == .primary ? 16 : 14)
                .frame(minHeight: 34)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static var capsulePrimary: CapsuleButtonStyle { CapsuleButtonStyle(kind: .primary) }
    static var capsuleSecondary: CapsuleButtonStyle { CapsuleButtonStyle(kind: .secondary) }
    static var capsuleTinted: CapsuleButtonStyle { CapsuleButtonStyle(kind: .tinted) }
}

#Preview("Capsule buttons") {
    HStack {
        Button("Import CSV") {}.buttonStyle(.capsuleSecondary)
        Button("Paste Cards") {}.buttonStyle(.capsuleSecondary)
        Button("Add Card") {}.buttonStyle(.capsulePrimary)
    }
    .padding(24)
    .background(Theme.Surface.previewBackdrop)
}

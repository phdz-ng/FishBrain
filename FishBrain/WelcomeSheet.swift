import SwiftUI

/// Shown once on first launch (and from Help > Welcome to FishBrain): how to get the widget and the
/// notch going.
struct WelcomeSheet: View {
    var hasGettingStartedDeck: Bool
    var onDismiss: () -> Void

    @Environment(\.accentChoice) private var accent

    private static let icons = ["rectangle.on.rectangle", "menubar.rectangle", "sparkles"]

    var body: some View {
        let steps = Welcome.steps(hasGettingStartedDeck: hasGettingStartedDeck)
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to FishBrain")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.TextColor.primary)
                Text("Flashcards that come to you: on your desktop and in the notch.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.TextColor.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: Self.icons[min(index, Self.icons.count - 1)])
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(accent.light)
                            .frame(width: 28, height: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title)
                                .font(Theme.Typography.body.weight(.semibold))
                                .foregroundStyle(Theme.TextColor.primary)
                            Text(step.detail)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.TextColor.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            HStack {
                Spacer()
                Button("Got it", action: onDismiss)
                    .buttonStyle(.capsulePrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480)
        .background {
            ZStack {
                Rectangle().fill(Theme.Blur.window)
                Rectangle().fill(Theme.Surface.window)
            }
        }
    }
}

#if DEBUG
#Preview("Welcome") {
    WelcomeSheet(hasGettingStartedDeck: true, onDismiss: {})
        .preferredColorScheme(.dark)
}
#endif

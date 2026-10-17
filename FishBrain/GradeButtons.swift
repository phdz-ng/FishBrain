import SwiftUI

/// Again, Hard, Good and Easy under a turned-over card, each with the gap it would set ("10 min",
/// "4 days"). In the notch, keys 1 to 4 pick them while it has the keyboard; in the main window they
/// don't, because they would fight with typing in the card list.
///
/// Disable the row (`.disabled`) while the card is still showing its front: it dims and says why.
struct GradeButtons: View {
    enum Size {
        /// The notch: a slim row.
        case compact
        /// The deck view's panel: taller buttons with larger text.
        case roomy
        /// The Review sprint: big buttons you hit without looking.
        case large

        fileprivate var height: CGFloat {
            switch self {
            case .compact: 32
            case .roomy: 48
            case .large: 68
            }
        }
        fileprivate var nameFont: Font {
            switch self {
            case .compact: Theme.Typography.micro.weight(.semibold)
            case .roomy: Theme.Typography.footnote.weight(.semibold)
            case .large: .system(size: 16, weight: .semibold)
            }
        }
        fileprivate var gapFont: Font {
            switch self {
            case .compact: .system(size: 9)
            case .roomy: .system(size: 10.5)
            case .large: .system(size: 12)
            }
        }
        fileprivate var spacing: CGFloat { self == .compact ? 1 : self == .roomy ? 2 : 3 }
        fileprivate var radius: CGFloat { self == .compact ? 9 : self == .roomy ? 10 : 14 }
    }

    var intervals: GradeIntervals
    var size: Size = .compact
    /// Keys 1 to 4. Off in the main window.
    var usesShortcuts = true
    var onGrade: (ReviewGrade) -> Void

    @Environment(\.accentChoice) private var accent
    @Environment(\.isEnabled) private var isEnabled

    /// What VoiceOver says for a button: "Good, next in 15 days".
    static func accessibilityLabel(_ grade: ReviewGrade, _ intervals: GradeIntervals) -> String {
        "\(grade.displayName), next in \(intervals.label(grade))"
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ReviewGrade.allCases, id: \.self) { grade in
                Button { onGrade(grade) } label: {
                    VStack(spacing: size.spacing) {
                        Text(grade.displayName)
                            .font(size.nameFont)
                        Text(intervals.label(grade))
                            .font(size.gapFont)
                            .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.6))
                    }
                    .foregroundStyle(Theme.TextColor.primary)
                    .frame(maxWidth: .infinity, minHeight: size.height)
                    .background(
                        RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                            .fill(grade == .good ? accent.fill.with(opacity: 0.45) : Theme.TextColor.primary.with(opacity: 0.11))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: size.radius, style: .continuous))
                }
                .buttonStyle(.plain)
                .modifier(GradeShortcut(grade: grade, isOn: usesShortcuts))
                .accessibilityLabel(Self.accessibilityLabel(grade, intervals))
                .accessibilityHint(hint(for: grade))
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
    }

    private func hint(for grade: ReviewGrade) -> String {
        if !isEnabled { return "Turn the card over first" }
        return usesShortcuts ? "Key \(grade.shortcutKey)" : ""
    }
}

/// The 1 to 4 key for a grade, when the buttons are in a place where bare keys are free.
private struct GradeShortcut: ViewModifier {
    var grade: ReviewGrade
    var isOn: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isOn {
            content.keyboardShortcut(KeyEquivalent(grade.shortcutKey), modifiers: [])
        } else {
            content
        }
    }
}

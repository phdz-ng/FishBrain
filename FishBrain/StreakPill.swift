import SwiftUI

/// The streak and daily goal pill: a flame and the streak, this week as seven dots, and today's count
/// against the goal. Reaching the goal fills today's dot with a short glow.
struct StreakPillContent: View {
    var study: StudySummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowing = false

    static let flame = Theme.Streak.flame

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Self.flame.color)
                    .accessibilityHidden(true)
                Text(study.streakText)
                    .font(Theme.Typography.micro.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.TextColor.primary)
            }
            weekDots
            Rectangle()
                .fill(Theme.TextColor.primary.with(opacity: 0.2))
                .frame(width: 1, height: 11)
            Text(study.progressText)
                .font(Theme.Typography.micro)
                .monospacedDigit()
                .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.62))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .onChange(of: study.goalMetToday) { wasMet, isMet in
            guard isMet, !wasMet else { return }
            celebrate()
        }
    }

    private var weekDots: some View {
        HStack(spacing: 4) {
            ForEach(Array(study.week.enumerated()), id: \.offset) { _, dot in
                dotView(dot)
            }
        }
        .accessibilityHidden(true)
    }

    private func dotView(_ dot: StudySummary.Dot) -> some View {
        let isGlowing = glowing && dot.isToday
        return Circle()
            .fill(fill(for: dot))
            .overlay {
                // Today is a ring, filled once its goal is met.
                if dot.isToday { Circle().strokeBorder(Self.flame.color, lineWidth: 1.5) }
            }
            .frame(width: 6, height: 6)
            .scaleEffect(isGlowing ? 1.6 : 1)
            .shadow(color: Self.flame.color.opacity(isGlowing ? 0.9 : 0), radius: isGlowing ? 5 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.5), value: isGlowing)
    }

    private func fill(for dot: StudySummary.Dot) -> Color {
        switch dot.state {
        case .met: Self.flame.color
        case .open: dot.isToday ? .clear : Theme.TextColor.primary.with(opacity: 0.22).color
        case .upcoming: Theme.TextColor.primary.with(opacity: 0.1).color
        }
    }

    /// A short glow on today's dot. With Reduce Motion nothing grows or pulses; the dot just fills.
    private func celebrate() {
        guard !reduceMotion else { return }
        glowing = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            glowing = false
        }
    }
}

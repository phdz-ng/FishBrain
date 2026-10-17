import SwiftUI

/// A thin progress ring: the share of the session that has passed.
struct SessionRing: View {
    var progress: Double
    var size: CGFloat = 13

    @Environment(\.accentChoice) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Theme.TextColor.primary.with(opacity: 0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(accent.light.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Reduce Motion: the ring just steps to its new place each second.
                .animation(reduceMotion ? nil : .linear(duration: 1), value: progress)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// What the drawn notch shows at rest for the study session: the ring, time left and cards reviewed
/// while it runs; the recap when it ends; and, if you chose this style, the last result.
struct SessionPillContent: View {
    var phase: SessionPhase
    var last: StudySession.Result?
    /// False while the notch is open or hidden: the clock stops redrawing then.
    var isActive: Bool

    var body: some View {
        Group {
            switch phase {
            case .running(let info):
                if isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { context in running(info, at: context.date) }
                } else {
                    running(info, at: Date())
                }
            case .recap(let result):
                label(symbol: "checkmark.circle.fill", text: result.text)
            case .idle:
                label(symbol: "timer", text: last?.lastText ?? "Start a session")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
    }

    private func running(_ info: SessionInfo, at date: Date) -> some View {
        HStack(spacing: 8) {
            SessionRing(progress: info.progress(at: date))
            Text(NowShowing.format(seconds: Int(info.remaining(at: date).rounded(.up))))
                .font(Theme.Typography.micro.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.TextColor.primary)
            Rectangle()
                .fill(Theme.TextColor.primary.with(opacity: 0.2))
                .frame(width: 1, height: 11)
            Text("\(info.reviewed) reviewed")
                .font(Theme.Typography.micro)
                .monospacedDigit()
                .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.62))
        }
    }

    private func label(symbol: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.62))
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Typography.micro.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.8))
        }
    }
}

/// The session controls in the open notch: Start session with its length, then the time left and the
/// cards reviewed with End session, then the recap.
struct SessionControls: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        switch model.session {
        case .idle:
            HStack(spacing: 6) {
                pill(action: { model.onStartSession(model.sessionMinutes) }) {
                    Label("Start session", systemImage: "play.fill").labelStyle(.titleAndIcon)
                }
                .accessibilityHint("Starts a \(model.sessionMinutes) minute session with a new card every 30 seconds")
                pill(action: cycleLength) { Text("\(model.sessionMinutes) min") }
                    .accessibilityLabel("Session length, \(model.sessionMinutes) minutes")
                    .accessibilityHint("Changes the length")
            }
        case .running(let info):
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(info.openText(at: context.date))
                        .font(Theme.Typography.micro)
                        .monospacedDigit()
                        .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.62))
                        .lineLimit(1)
                }
                // One clock at a time: while a sprint runs, Start session gives way to Go to sprint.
                if info.kind == .sprint {
                    pill(action: model.onGoToSprint) { Text("Go to sprint") }
                        .accessibilityHint("Brings FishBrain forward to the Review sprint")
                } else {
                    pill(action: model.onEndSession) { Text("End session") }
                }
            }
        case .recap(let result):
            Label(result.text, systemImage: "checkmark.circle.fill")
                .font(Theme.Typography.micro.weight(.semibold))
                .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.8))
                .lineLimit(1)
        }
    }

    /// 5, 10, 15, 25 and round again. A button rather than a menu, which a panel that never takes
    /// focus can't reliably pop up.
    private func cycleLength() {
        let lengths = StudySession.lengths
        let index = lengths.firstIndex(of: model.sessionMinutes) ?? 0
        model.onSetSessionMinutes(lengths[(index + 1) % lengths.count])
    }

    private func pill<Label: View>(action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .font(Theme.Typography.micro.weight(.semibold))
                .foregroundStyle(Theme.TextColor.primary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(Theme.TextColor.primary.with(opacity: 0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

import AppKit
import SwiftUI

/// The Review sprint's two full-window screens: the running one (time, card, four big grade buttons)
/// and the results.
struct ReviewSprintView: View {
    @ObservedObject var model: ReviewSprintModel
    var onSameMix: () -> Void
    var onFollowUp: (ReviewResults) -> Void
    var onDone: () -> Void

    @EnvironmentObject private var study: StudyStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accentChoice) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let contentWidth: CGFloat = 700

    var body: some View {
        Group {
            switch model.phase {
            case .running: running
            case .finished: results
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Twice a second is plenty for a clock shown in whole seconds.
            while !Task.isCancelled, model.isRunning {
                model.tick()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onAppear {
            model.onAnnouncement = { text in
                NSAccessibility.post(
                    element: NSApp as Any, notification: .announcementRequested,
                    userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
                )
            }
        }
        // Grading counts toward today's goal, which lives in the study log.
        .onChange(of: model.reviewed) { _, _ in study.refresh() }
    }

    // MARK: Running

    private var running: some View {
        VStack(spacing: 0) {
            topBar
            counters
                .padding(.top, 8)
            LearnTrack(
                progress: model.trackProgress(reduceMotion: reduceMotion), step: model.reviewed,
                reduceMotion: reduceMotion, label: "Time"
            )
            .frame(maxWidth: Self.contentWidth)
            .padding(.horizontal, 32)
            .padding(.top, 12)
            cardArea
                .padding(.top, 14)
            VStack(spacing: 8) {
                GradeButtons(intervals: model.intervals, size: .large, onGrade: model.grade)
                    .disabled(!model.canGrade)
                keyHints
            }
            .frame(maxWidth: Self.contentWidth)
            .padding(.horizontal, 32)
            .padding(.top, 14)
            .padding(.bottom, 22)
        }
        .alert("End this sprint?", isPresented: $model.isConfirmingEnd) {
            Button("End sprint", role: .destructive) { model.confirmEnd() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text(model.reviewed == 0 ? "Nothing has been graded yet." : "You'll see how it went. \(model.reviewed) \(model.reviewed == 1 ? "card" : "cards") reviewed so far.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("End sprint") { model.handle(.escape) }
                .buttonStyle(.capsuleSecondary)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 12)
            Text(model.title)
                .lineLimit(1)
            Spacer(minLength: 12)
            Button(model.isPaused ? "Resume" : "Pause") { model.handle(.pause) }
                .buttonStyle(.capsuleSecondary)
                .keyboardShortcut("p", modifiers: [])
                .disabled(model.isTimeUp)
                .opacity(model.isTimeUp ? 0.5 : 1)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.TextColor.secondary)
        .padding(.leading, 100) // the window's traffic lights sit over the hidden title bar
        .padding(.trailing, 28)
        .padding(.top, 14)
    }

    private var counters: some View {
        HStack(alignment: .bottom) {
            counter("\(model.reviewed)", "reviewed", alignment: .leading)
            Spacer(minLength: 8)
            VStack(spacing: 2) {
                Text(ReviewResults.clock(model.remaining.rounded(.up)))
                    .font(.system(size: 56, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(model.isTimeUp ? accent.light : Theme.TextColor.primary)
                    .accessibilityLabel(Self.spokenTime(model.remaining))
                    .accessibilityAddTraits(.updatesFrequently)
                Text(model.isPaused ? "paused" : "left")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.secondary)
            }
            Spacer(minLength: 8)
            counter("\(model.dueLeft)", "due left", alignment: .trailing, tint: accent.light)
        }
        .frame(maxWidth: Self.contentWidth)
        .padding(.horizontal, 32)
    }

    private func counter(_ value: String, _ label: String, alignment: HorizontalAlignment, tint: Token = Theme.TextColor.primary) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(value)
                .font(.system(size: 36, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.TextColor.secondary)
        }
        .frame(width: 130, alignment: alignment == .leading ? .leading : .trailing)
        .accessibilityElement(children: .combine)
    }

    private var cardArea: some View {
        VStack(spacing: 10) {
            if model.isTimeUp {
                Text("Time's up · grade this card to finish")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(accent.light)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(accent.flippedSurface))
            }
            if let shown = model.current {
                Button { model.handle(.space) } label: {
                    FlipView(
                        angle: NotchCard.flipAngle(isFlipped: model.isFlipped),
                        style: NotchCard.flipStyle(reduceMotion: reduceMotion),
                        front: face(shown, isBack: false),
                        back: face(shown, isBack: true)
                    )
                    .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.5), value: model.isFlipped)
                    .blur(radius: model.isPaused ? 22 : 0)
                    .overlay {
                        if model.isPaused {
                            Text("Paused")
                                .font(Theme.Typography.title)
                                .foregroundStyle(Theme.TextColor.primary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .id(shown.card.id)
                .frame(maxWidth: Self.contentWidth, maxHeight: 330)
                .padding(.horizontal, 32)
                .accessibilityLabel(model.isPaused ? "Paused" : CardFace.accessibilityText(
                    model.isFlipped ? shown.card.back : shown.card.front, isBack: model.isFlipped,
                    image: model.isFlipped ? shown.card.backImage : shown.card.frontImage
                ))
                .accessibilityHint(model.isFlipped ? "Grades the card Good" : "Flips the card")
            } else {
                Spacer()
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func face(_ shown: (card: Card, deck: Deck), isBack: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.widget, style: .continuous)
        return VStack(spacing: 0) {
            if model.showsDeckName {
                HStack {
                    Spacer()
                    Text(shown.deck.name)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.TextColor.meta(isFlipped: isBack))
                        .lineLimit(1)
                }
                .padding(.bottom, 4)
            }
            CardFace(
                text: isBack ? shown.card.back : shown.card.front, isBack: isBack, size: .sprint,
                image: isBack ? shown.card.backImage : shown.card.frontImage
            )
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(isBack ? accent.flippedSurface : Theme.Surface.widget))
        .overlay { shape.strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
    }

    private var keyHints: some View {
        HStack(spacing: 0) {
            ForEach(Array(ReviewGrade.allCases.enumerated()), id: \.offset) { _, grade in
                keycap(grade == .good ? "3 or Space" : String(grade.shortcutKey))
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.footnote)
            .foregroundStyle(Theme.TextColor.cardBack)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.Surface.control))
    }

    /// "7 minutes 42 seconds", for VoiceOver.
    static func spokenTime(_ remaining: TimeInterval) -> String {
        let whole = max(Int(remaining.rounded(.up)), 0)
        let minutes = whole / 60, seconds = whole % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        if seconds > 0 || minutes == 0 { parts.append("\(seconds) \(seconds == 1 ? "second" : "seconds")") }
        return parts.joined(separator: " ") + " left"
    }

    // MARK: Results

    private var results: some View {
        let results = model.results(study: study.summary(at: Date(), goal: settings.dailyGoal))
        return ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text(results.headline)
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(accent.light)
                    Text("\(results.count)")
                        .font(.system(size: 88, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.TextColor.primary)
                    Text(results.paceLine)
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.TextColor.cardBack)
                }
                .accessibilityElement(children: .combine)

                HStack(spacing: 12) {
                    if let pace = results.usualPaceText { statChip("Your usual pace", pace) }
                    if let last = results.lastSprintText { statChip("Last sprint", last) }
                    statChip("Remembered (Good or Easy)", results.rememberedText, highlighted: true)
                }

                gradeBar(results)

                if let goal = results.goalLine {
                    HStack(spacing: 10) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(Theme.Streak.flame)
                            .accessibilityHidden(true)
                        Text(goal)
                    }
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.TextColor.cardBack)
                }

                HStack(alignment: .top, spacing: 14) {
                    if results.deckCount > 1 { byDeck(results) }
                    if !results.again.isEmpty { cameUpAgain(results) }
                }

                HStack(spacing: 10) {
                    if let title = results.followUpTitle {
                        Button(title) { onFollowUp(results) }.buttonStyle(.capsuleTinted)
                    }
                    Button("Same mix again", action: onSameMix).buttonStyle(.capsuleSecondary)
                    Button("Done", action: onDone)
                        .buttonStyle(.capsulePrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: 800)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .onExitCommand(perform: onDone)
    }

    private func statChip(_ title: String, _ value: String, highlighted: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(Theme.Typography.footnote)
                .foregroundStyle(highlighted ? Theme.TextColor.cardBack : Theme.TextColor.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.TextColor.primary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(highlighted ? accent.flippedSurface : Theme.Surface.window))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
    }

    private func gradeColor(_ grade: ReviewGrade) -> Token {
        switch grade {
        case .again: Theme.Status.problem
        case .hard: Theme.Status.learning
        case .good: accent.fill
        case .easy: Theme.Status.ok
        }
    }

    private func gradeBar(_ results: ReviewResults) -> some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let shown = results.gradeFractions.filter { $0.fraction > 0 }
                let gaps = CGFloat(max(shown.count - 1, 0)) * 3
                HStack(spacing: 3) {
                    ForEach(shown, id: \.grade) { item in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(gradeColor(item.grade))
                            .frame(width: max((geometry.size.width - gaps) * item.fraction, 4))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            HStack {
                ForEach(ReviewGrade.allCases, id: \.self) { grade in
                    HStack(spacing: 5) {
                        Circle().fill(gradeColor(grade)).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text("\(results.gradeCounts[grade] ?? 0)").fontWeight(.semibold).foregroundStyle(Theme.TextColor.primary)
                        Text(grade.displayName)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.TextColor.cardBack)
        }
    }

    private func byDeck(_ results: ReviewResults) -> some View {
        panel("By deck") {
            ForEach(results.byDeck, id: \.deckID) { row in
                HStack(spacing: 10) {
                    Text(row.name)
                        .lineLimit(1)
                        .frame(width: 128, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.Surface.progressTrack)
                            Capsule().fill(accent.light).frame(width: geometry.size.width * row.fraction)
                        }
                    }
                    .frame(height: 6)
                    .accessibilityHidden(true)
                    Text("\(row.count)").fontWeight(.semibold).monospacedDigit()
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.TextColor.primary)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func cameUpAgain(_ results: ReviewResults) -> some View {
        panel("Came up again (\(results.again.count))") {
            ForEach(results.again, id: \.cardID) { row in
                HStack {
                    Text(row.front).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(row.deckName)
                        .lineLimit(1)
                        .foregroundStyle(Theme.TextColor.secondary)
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.TextColor.primary)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.TextColor.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Surface.window))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
    }
}

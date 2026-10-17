import SwiftUI

/// "Review sprint": tick what to mix, how long, which cards. Opened from Review in a deck's header.
struct ReviewSetupSheet: View {
    /// The deck the sheet was opened from: the "This deck" chip.
    var initialDeckID: Deck.ID?
    /// The subject whose page is open, for its chip.
    var currentSubjectID: Subject.ID?
    /// Past sprints' pace, once there is history; nil hides the estimate.
    var history: ReviewResults.History = .empty
    var onStart: (ReviewSetup) -> Void
    var onCancel: () -> Void

    static let width: CGFloat = 880
    /// Wide enough for 5, 10, 15, 25 and Custom in one row.
    static let optionsWidth: CGFloat = 400

    @EnvironmentObject private var store: DeckStore
    @EnvironmentObject private var playback: PlaybackStore
    @Environment(\.accentChoice) private var accent
    @State private var setup: ReviewSetup
    @State private var now = Date()
    @State private var isCustomLength = false

    /// - Parameter initialTicked: the decks that start ticked; with none, just `initialDeckID`.
    init(
        initialDeckID: Deck.ID?, initialTicked: Set<Deck.ID>? = nil, currentSubjectID: Subject.ID? = nil,
        minutes: Int, history: ReviewResults.History = .empty,
        onStart: @escaping (ReviewSetup) -> Void, onCancel: @escaping () -> Void
    ) {
        self.initialDeckID = initialDeckID
        self.currentSubjectID = currentSubjectID
        self.history = history
        self.onStart = onStart
        self.onCancel = onCancel
        let ticked = initialTicked ?? initialDeckID.map { [$0] } ?? []
        _setup = State(initialValue: ReviewSetup(ticking: ticked, minutes: minutes))
    }

    private var summary: ReviewSetupSummary {
        ReviewSetupSummary(
            decks: store.decks, playback: playback.states, setup: setup, now: now, usualPace: history.usualPace
        )
    }

    var body: some View {
        let summary = summary
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review sprint")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.TextColor.primary)
                Text("Tick any decks or subjects to mix them in one sprint.")
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.TextColor.cardBack)
            }
            HStack(alignment: .top, spacing: 32) {
                checklist(summary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                options(summary)
                    .frame(width: Self.optionsWidth, alignment: .topLeading)
            }
            footer(summary)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
        .frame(width: Self.width)
        .onAppear { now = Date() }
    }

    // MARK: What to review

    private func checklist(_ summary: ReviewSetupSummary) -> some View {
        let rows = ReviewChecklist.rows(
            subjects: store.subjects, decks: store.decks, ticked: setup.ticked, playback: playback.states, now: now
        )
        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("What to review")
            HStack(spacing: 6) {
                if let initialDeckID, store.decks.contains(where: { $0.id == initialDeckID }) {
                    chip("This deck") { setup.tickOnly(initialDeckID) }
                }
                if let currentSubjectID, let subject = store.subjects.first(where: { $0.id == currentSubjectID }) {
                    Button {
                        setup.tickDecks(in: currentSubjectID, subjects: store.subjects, decks: store.decks)
                    } label: {
                        Text(subject.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 110)
                    }
                    .buttonStyle(.capsuleSecondary)
                    .fixedSize()
                    .accessibilityHint("Ticks every deck in \(subject.name)")
                }
                chip("Everything due") { setup.tickEverythingDue(decks: store.decks, playback: playback.states, now: now) }
                Button("Clear") { setup.clear() }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(accent.light)
                    .padding(.horizontal, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in checklistRow(row) }
                    if rows.isEmpty {
                        Text("No decks yet")
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(Theme.TextColor.secondary)
                            .padding(10)
                    }
                }
                .padding(6)
            }
            .frame(height: 230)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Surface.window))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.summaryLine)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.cardBack)
                    .accessibilityLabel(summary.summaryLine.replacingOccurrences(of: " · ", with: ", "))
            }
        }
    }

    /// One subject or deck: a tick that is clear, a dash (some of what is inside) or a check, then its
    /// icon and name, indented as the library is, and how much is due.
    private func checklistRow(_ row: ReviewChecklist.Row) -> some View {
        Button {
            setup.ticked = ReviewChecklist.toggled(row, in: setup.ticked)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tickSymbol(row.tick))
                    .font(.system(size: 15))
                    .foregroundStyle(row.tick == .off ? Theme.TextColor.secondary : accent.light)
                    .accessibilityHidden(true)
                switch row.kind {
                case .subject: SubjectIcon(color: row.color, size: 18)
                case .deck: DeckIcon(color: row.color, size: 18)
                }
                Text(row.name)
                    .font(Theme.Typography.rowTitle.weight({
                        if case .subject = row.kind { .semibold } else { .regular }
                    }()))
                    .foregroundStyle(Theme.TextColor.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(row.statusText)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(row.isEnabled && row.dueCount == 0 && row.cardCount > 0 ? Theme.Status.ok : Theme.TextColor.cardBack)
            }
            .padding(.leading, 8 + CGFloat(row.indent) * 18)
            .padding(.trailing, 8)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.isEnabled)
        .opacity(row.isEnabled ? 1 : 0.45)
        .accessibilityLabel(row.accessibilityText)
        .accessibilityAddTraits(row.tick == .on ? .isSelected : [])
    }

    private func tickSymbol(_ tick: ReviewChecklist.Tick) -> String {
        switch tick {
        case .off: "square"
        case .mixed: "minus.square.fill"
        case .on: "checkmark.square.fill"
        }
    }

    // MARK: Options

    private func options(_ summary: ReviewSetupSummary) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("How long")
                HStack(spacing: 8) {
                    ForEach(ReviewRun.lengths, id: \.self) { minutes in
                        let isOn = !isCustomLength && setup.minutes == minutes
                        Button("\(minutes) min") {
                            isCustomLength = false
                            setup.setMinutes(minutes)
                        }
                        .buttonStyle(isOn ? .capsulePrimary : .capsuleSecondary)
                        .fixedSize()
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                    let customIsOn = isCustomLength || !ReviewRun.lengths.contains(setup.minutes)
                    Button("Custom") { isCustomLength = true }
                        .buttonStyle(customIsOn ? .capsulePrimary : .capsuleSecondary)
                        .fixedSize()
                        .accessibilityAddTraits(customIsOn ? .isSelected : [])
                }
                if isCustomLength || !ReviewRun.lengths.contains(setup.minutes) {
                    Stepper(value: Binding(get: { setup.minutes }, set: { setup.setMinutes($0) }), in: ReviewRun.minutesRange) {
                        Text("\(setup.minutes) \(setup.minutes == 1 ? "minute" : "minutes")")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.TextColor.primary)
                    }
                    .accessibilityLabel("Minutes")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Which cards")
                VStack(spacing: 0) {
                    cardsRow("Due first, then new", .dueThenNew, summary)
                    HairlineDivider()
                    cardsRow("Due only", .dueOnly, summary)
                    HairlineDivider()
                    cardsRow("Everything, shuffled", .everythingShuffled, summary)
                }
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Toggle(isOn: $setup.shuffleBetweenDecks) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shuffle between decks")
                        .font(Theme.Typography.rowTitle.weight(.semibold))
                        .foregroundStyle(Theme.TextColor.primary)
                    Text("Off: the most overdue card comes first, whichever deck it is in. On: decks take turns, which helps you tell similar things apart.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(setup.cards == .everythingShuffled)
            if let estimate = summary.estimateLine {
                Label(estimate, systemImage: "chart.line.uptrend.xyaxis")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.cardBack)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.TextColor.primary.with(opacity: 0.05)))
            }
        }
    }

    private func cardsRow(_ title: String, _ cards: ReviewQueue.Options.Cards, _ summary: ReviewSetupSummary) -> some View {
        let isOn = setup.cards == cards
        return Button { setup.cards = cards } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? accent.light : Theme.TextColor.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Theme.Typography.rowTitle.weight(isOn ? .semibold : .regular))
                    .foregroundStyle(Theme.TextColor.primary)
                Spacer(minLength: 8)
                Text(summary.countText(for: cards))
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(isOn ? Theme.TextColor.cardBack : Theme.TextColor.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? accent.flippedSurface : Theme.TextColor.primary.with(opacity: 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(summary.countText(for: cards))")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: Footer

    private func footer(_ summary: ReviewSetupSummary) -> some View {
        HStack(spacing: 10) {
            Spacer()
            if let reason = summary.startDisabledReason {
                Text(reason)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
            }
            Button("Cancel", action: onCancel)
                .buttonStyle(.capsuleSecondary)
                .keyboardShortcut(.cancelAction)
            Button { onStart(setup) } label: { Label(summary.startTitle, systemImage: "play.fill") }
                .buttonStyle(.capsulePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(summary.startDisabledReason != nil)
                .opacity(summary.startDisabledReason == nil ? 1 : 0.5)
        }
    }

    // MARK: Pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.footnote.weight(.semibold))
            .foregroundStyle(Theme.TextColor.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).lineLimit(1) }
            .buttonStyle(.capsuleSecondary)
            .fixedSize()
    }
}

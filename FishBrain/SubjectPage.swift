import SwiftUI

/// A subject's page: its name and colour, a breadcrumb back up when it is nested, and tiles for the
/// subjects and decks inside it, each with a bar of where its cards stand.
struct SubjectPageView: View {
    var subject: Subject
    @Binding var isRenaming: Bool
    var onOpenSubject: (Subject.ID) -> Void
    var onOpenDeck: (Deck.ID) -> Void
    var onNewDeck: (Subject.ID) -> Void
    var onNewSubject: (Subject.ID) -> Void
    var onLearn: (Deck.ID) -> Void
    var onReview: (Deck.ID) -> Void
    /// "Learn all" and "Review…" for a subject (this one, or a tile's): every deck inside it.
    var onLearnSubject: (Subject.ID) -> Void = { _ in }
    var onReviewSubject: (Subject.ID) -> Void = { _ in }
    var onRename: (String) -> Void
    var onSetColor: (DeckColor) -> Void
    /// Where this subject may be moved to, choosing one, and deleting it.
    var destinations: LibraryMove.Destinations = .none
    var onMoveTo: (Subject.ID?) -> Void = { _ in }
    var onDelete: () -> Void = {}
    /// Opens the Export sheet for this subject and everything inside it.
    var onExport: () -> Void = {}
    /// Opens the Import sheet to bring cards, decks and subjects into this subject.
    var onImport: () -> Void = {}
    /// Why Export… is off (nothing to export), or nil.
    var exportReason: String?
    /// The appearance setting, for the round button after Review…; nil leaves it out.
    var appearance: Binding<AppearanceChoice>?

    @EnvironmentObject private var store: DeckStore
    @EnvironmentObject private var playback: PlaybackStore
    @Environment(\.accentChoice) private var accent
    @State private var isPickingColor = false

    private var tree: SubjectTree { store.subjectTree }

    var body: some View {
        // Due changes with the clock, so the counts are looked at again every minute.
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let summary = SubjectSummary(subject: subject.id, tree: tree, decks: store.decks, playback: playback.states, now: now)
        let childSubjects = tree.children(of: subject.id)
        let childDecks = store.decks.filter { $0.subjectID == subject.id }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(summary: summary)
                if summary.isEmpty {
                    emptyState
                } else {
                    if !childSubjects.isEmpty {
                        section("Subjects inside") {
                            ForEach(childSubjects) { child in
                                subjectTile(child, now: now)
                            }
                        }
                    }
                    section("Decks") {
                        ForEach(childDecks) { deck in deckTile(deck, now: now) }
                        NewDeckTile(subjectName: subject.name) { onNewDeck(subject.id) }
                    }
                    legend
                }
            }
            .padding(.top, 38)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private func header(summary: SubjectSummary) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                let ancestors = Array(tree.ancestors(of: subject.id).reversed())
                if !ancestors.isEmpty {
                    SubjectBreadcrumb(path: ancestors, current: nil, onOpen: onOpenSubject)
                }
                HStack(spacing: 12) {
                    Button { isPickingColor = true } label: { SubjectIcon(color: subject.color, size: 30) }
                        .buttonStyle(.plain)
                        .help("Change subject color")
                        .accessibilityLabel("Subject color, \(subject.color.displayName)")
                        .popover(isPresented: $isPickingColor, arrowEdge: .bottom) {
                            DeckColorPicker(selection: subject.color) { color in
                                onSetColor(color)
                                isPickingColor = false
                            }
                        }
                    EditableTitle(text: subject.name, isEditing: $isRenaming, onCommit: onRename, placeholder: "Subject name", hint: "Renames the subject")
                }
                Text(summary.pageSubtitle)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.TextColor.secondary)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                subjectButtons(summary)
                if let appearance { AppearanceButton(selection: appearance) }
                moreMenu
                newMenu
            }
        }
    }

    /// Learn all and Review…: through every card in every deck in this subject. Off, with the reason as
    /// a tooltip, while there is nothing in it.
    @ViewBuilder
    private func subjectButtons(_ summary: SubjectSummary) -> some View {
        let availability = summary.cardsAvailability
        HStack(spacing: 8) {
            Button("Learn all") { onLearnSubject(subject.id) }
                .buttonStyle(.capsuleSecondary)
                .disabled(!availability.isEnabled)
                .opacity(availability.isEnabled ? 1 : 0.5)
                .help(availability.reason ?? "Go through every card in this subject, deck by deck")
                .accessibilityHint("Goes through every card in \(subject.name)")
            Button { onReviewSubject(subject.id) } label: { Label("Review…", systemImage: "timer") }
                .buttonStyle(.capsulePrimary)
                .disabled(!availability.isEnabled)
                .opacity(availability.isEnabled ? 1 : 0.5)
                .help(availability.reason ?? "Review every deck in this subject against the clock")
                .accessibilityHint("Opens the Review sprint with every deck in \(subject.name) ticked")
        }
    }

    /// Move to… and Delete…, for the subject itself.
    private var moreMenu: some View {
        Menu {
            MoveToMenu(destinations: destinations, onMove: onMoveTo)
            Button("Import…", action: onImport)
            Button("Export…", action: onExport)
                .disabled(exportReason != nil)
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18)
        }
        .menuStyle(.button)
        .buttonStyle(.capsuleSecondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
        .accessibilityHint("Move, import into, export or delete \(subject.name)")
    }

    private var newMenu: some View {
        let items = NewMenu.items(in: subject.id, tree: tree).filter {
            if case .newDeckIn = $0.action { return true }
            if case .newSubjectIn = $0.action { return true }
            return false
        }
        return Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index == 1 { Divider() }
                Button(item.title) { choose(item.action) }.disabled(!item.isEnabled)
                if let reason = item.disabledReason { Text(reason) }
            }
        } label: {
            HStack(spacing: 8) {
                Text("New")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.capsuleSecondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("New")
        .accessibilityHint("A deck or a subject in \(subject.name)")
    }

    private func choose(_ action: NewMenu.Action) {
        switch action {
        case .newDeckIn(let id): onNewDeck(id)
        case .newSubjectIn(let id): onNewSubject(id)
        case .newDeck, .newSubject, .importFile: break
        }
    }

    // MARK: Tiles

    private func subjectTile(_ child: Subject, now: Date) -> some View {
        let summary = SubjectSummary(subject: child.id, tree: tree, decks: store.decks, playback: playback.states, now: now)
        return SubjectTile(
            subject: child, summary: summary, onOpen: { onOpenSubject(child.id) },
            onLearn: { onLearnSubject(child.id) }, onReview: { onReviewSubject(child.id) }
        )
    }

    private func deckTile(_ deck: Deck, now: Date) -> some View {
        DeckTile(
            deck: deck, breakdown: StatusBreakdown(cards: deck.cards, state: playback.states[deck.id], now: now),
            onOpen: { onOpenDeck(deck.id) }, onLearn: { onLearn(deck.id) }, onReview: { onReview(deck.id) }
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.TextColor.secondary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 340), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                content()
            }
        }
    }

    // MARK: Empty, legend

    private var emptyState: some View {
        let canAddSubject = tree.canAdd(under: subject.id)
        return VStack(spacing: 14) {
            SubjectIcon(color: subject.color, size: 44)
            Text("Nothing in \(subject.name) yet")
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.TextColor.primary)
            Text("A subject holds decks, and other subjects. Add a deck to start, or a subject to group decks inside it.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.TextColor.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 8) {
                Button("New Deck") { onNewDeck(subject.id) }.buttonStyle(.capsulePrimary)
                Button("New Subject") { onNewSubject(subject.id) }
                    .buttonStyle(.capsuleSecondary)
                    .disabled(!canAddSubject)
                    .opacity(canAddSubject ? 1 : 0.5)
                    .help(canAddSubject ? "" : NewMenu.subjectItem(in: subject, tree: tree).disabledReason ?? "")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).fill(Theme.Surface.group))
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
    }

    private var legend: some View {
        HStack(spacing: 18) {
            ForEach([StatusBreakdown.Segment.mastered, .young, .learning, .new], id: \.self) { segment in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(StatusBar.color(for: segment, accent: accent).color).frame(width: 10, height: 8)
                    Text(StatusBar.title(for: segment))
                }
            }
        }
        .font(Theme.Typography.footnote)
        .foregroundStyle(Theme.TextColor.secondary)
        .accessibilityHidden(true)
    }
}

/// "Spanish › Grammar": every part but the last way back up.
struct SubjectBreadcrumb: View {
    var path: [Subject]
    /// The name shown last, not clickable (the page's own).
    var current: String?
    var onOpen: (Subject.ID) -> Void

    @Environment(\.accentChoice) private var accent

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(path.enumerated()), id: \.element.id) { index, subject in
                if index > 0 { separator }
                Button(subject.name) { onOpen(subject.id) }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent.light)
                    .accessibilityHint("Opens the subject")
            }
            if let current {
                separator
                Text(current).foregroundStyle(Theme.TextColor.cardBack)
            }
        }
        .font(Theme.Typography.footnote)
        .lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    private var separator: some View {
        Text("›").foregroundStyle(Theme.TextColor.secondary).accessibilityHidden(true)
    }
}

/// Mastered, young, learning and new as one stacked bar.
struct StatusBar: View {
    var breakdown: StatusBreakdown

    @Environment(\.accentChoice) private var accent

    static func color(for segment: StatusBreakdown.Segment, accent: AccentChoice) -> Token {
        switch segment {
        case .mastered: Theme.Status.ok
        case .young: accent.light
        case .learning: Theme.Status.learning
        case .new: Theme.TextColor.secondary.with(opacity: 0.55)
        }
    }

    static func title(for segment: StatusBreakdown.Segment) -> String {
        switch segment {
        case .mastered: "Mastered (next review 21 days or more away)"
        case .young: "Young"
        case .learning: "Learning"
        case .new: "New"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let shown = breakdown.segments.filter { $0.fraction > 0 }
            let gaps = CGFloat(max(shown.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(shown, id: \.segment) { item in
                    Rectangle()
                        .fill(Self.color(for: item.segment, accent: accent).color)
                        .frame(width: max((geometry.size.width - gaps) * item.fraction, 3))
                }
                if shown.isEmpty { Rectangle().fill(Theme.Surface.progressTrack.color) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

private struct TileButtonStyle: ButtonStyle {
    var isTinted = false

    @Environment(\.accentChoice) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.footnote.weight(.medium))
            .foregroundStyle(isTinted ? accent.light : Theme.TextColor.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(Capsule().fill(isTinted ? accent.flippedSurface : Theme.Surface.control))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A subject inside this page, with a stacked-card look: a tile with two more behind it, and Learn and
/// Review for everything inside it.
struct SubjectTile: View {
    var subject: Subject
    var summary: SubjectSummary
    var onOpen: () -> Void
    var onLearn: () -> Void = {}
    var onReview: () -> Void = {}

    @Environment(\.accentChoice) private var accent

    var body: some View {
        let availability = summary.cardsAvailability
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        SubjectIcon(color: subject.color, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(subject.name)
                                .font(Theme.Typography.body.weight(.semibold))
                                .foregroundStyle(Theme.TextColor.primary)
                                .lineLimit(1)
                            Text(summary.tileSubtitle)
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.TextColor.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    StatusBar(breakdown: summary.breakdown)
                    Text(summary.breakdown.summaryText)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.cardBack)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.accessibilityText(name: subject.name))
            .accessibilityHint("Opens the subject")

            HStack(spacing: 6) {
                Button("Learn", action: onLearn)
                    .buttonStyle(TileButtonStyle())
                    .disabled(!availability.isEnabled)
                    .help(availability.reason ?? "Go through every card inside, deck by deck")
                Button("Review", action: onReview)
                    .buttonStyle(TileButtonStyle(isTinted: true))
                    .disabled(!availability.isEnabled)
                    .help(availability.reason ?? "Review every deck inside against the clock")
            }
            .opacity(availability.isEnabled ? 1 : 0.5)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).fill(Theme.Surface.group))
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
        .background(alignment: .bottom) {
            // Two more cards behind, a little lower and narrower.
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                    .fill(Theme.Surface.group.color).opacity(0.6).padding(.horizontal, 12).offset(y: 9)
                RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                    .fill(Theme.Surface.group.color).opacity(0.35).padding(.horizontal, 6).offset(y: 5)
            }
        }
        .padding(.bottom, 10)
    }
}

/// A deck inside this page: its name, the bar, the counts, and Learn and Review for it.
struct DeckTile: View {
    var deck: Deck
    var breakdown: StatusBreakdown
    var onOpen: () -> Void
    var onLearn: () -> Void
    var onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        DeckIcon(color: deck.color, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(deck.name)
                                .font(Theme.Typography.body.weight(.semibold))
                                .foregroundStyle(Theme.TextColor.primary)
                                .lineLimit(1)
                            Text("\(deck.cards.count) \(deck.cards.count == 1 ? "card" : "cards")")
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.TextColor.secondary)
                        }
                    }
                    StatusBar(breakdown: breakdown)
                    Text(breakdown.summaryText)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.cardBack)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(deck.name), deck, \(deck.cards.count) \(deck.cards.count == 1 ? "card" : "cards")"
                    + (breakdown.due > 0 ? ", \(breakdown.due) due" : "")
            )
            .accessibilityHint("Opens the deck")

            HStack(spacing: 6) {
                Button("Learn", action: onLearn)
                    .buttonStyle(TileButtonStyle())
                    .disabled(deck.cards.isEmpty)
                Button("Review", action: onReview)
                    .buttonStyle(TileButtonStyle(isTinted: true))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).fill(Theme.Surface.group))
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
    }
}

/// The dashed tile that makes a deck in this subject.
struct NewDeckTile: View {
    var subjectName: String
    var onNew: () -> Void

    @Environment(\.accentChoice) private var accent

    var body: some View {
        Button(action: onNew) {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 20, weight: .regular)).accessibilityHidden(true)
                Text("New deck in \(subjectName)").font(Theme.Typography.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(accent.light)
            .frame(maxWidth: .infinity, minHeight: 130)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                    .strokeBorder(Theme.TextColor.primary.with(opacity: 0.2), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New deck in \(subjectName)")
    }
}

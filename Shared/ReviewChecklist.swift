import Foundation

/// The setup sheet's "What to review" list: subjects and decks as a tree mirroring the library, each row
/// with how much is due, and a tick state that follows from which decks are ticked. Pure.
///
/// What is ticked is always a set of **deck ids**: ticking a subject ticks every deck inside it, and a
/// subject shows as ticked, partly ticked or clear from those. Start resolves the set once, so moving a
/// deck about afterwards can't change the sprint.
struct ReviewChecklist: Sendable {
    enum Tick: Equatable, Sendable {
        case off
        /// Some of what is inside, shown as a dash.
        case mixed
        case on
    }

    struct Row: Equatable, Identifiable, Sendable {
        enum Kind: Equatable, Sendable {
            case subject(Subject.ID)
            case deck(Deck.ID)
        }

        var kind: Kind
        var name: String
        var color: DeckColor
        /// How far in it is shown: a top-level subject or a loose deck is 0.
        var indent: Int
        var tick: Tick
        /// A subject with no deck anywhere inside can't be ticked.
        var isEnabled: Bool
        /// Due now, in everything inside.
        var dueCount: Int
        var cardCount: Int
        /// The decks that ticking this row ticks (a deck's own id for a deck).
        var deckIDs: [Deck.ID]

        var id: String {
            switch kind {
            case .subject(let id): "subject-\(id.uuidString)"
            case .deck(let id): "deck-\(id.uuidString)"
            }
        }

        /// "14 due", "Caught up", or "Empty" for a subject with nothing inside.
        var statusText: String {
            if !isEnabled { return "No decks" }
            if cardCount == 0 { return "No cards" }
            return dueCount == 0 ? "Caught up" : "\(dueCount) due"
        }

        /// What VoiceOver says: "Grammar, 5 due, partly ticked".
        var accessibilityText: String {
            let tickText = switch tick {
            case .off: "not ticked"
            case .mixed: "partly ticked"
            case .on: "ticked"
            }
            return "\(name), \(statusText), \(tickText)"
        }
    }

    /// Every subject (all levels) with its sub-subjects and then its own decks beneath it, then the loose
    /// decks, the order the sidebar uses.
    static func rows(
        subjects: [Subject], decks: [Deck], ticked: Set<Deck.ID>, playback: [Deck.ID: PlaybackState], now: Date
    ) -> [Row] {
        let tree = SubjectTree(subjects)
        let known = Set(subjects.map(\.id))

        func tick(for ids: [Deck.ID]) -> Tick {
            guard !ids.isEmpty else { return .off }
            let count = ids.filter(ticked.contains).count
            return count == 0 ? .off : (count == ids.count ? .on : .mixed)
        }
        func deckRow(_ deck: Deck, indent: Int) -> Row {
            Row(
                kind: .deck(deck.id), name: deck.name, color: deck.color, indent: indent,
                tick: ticked.contains(deck.id) ? .on : .off, isEnabled: true,
                dueCount: playback[deck.id]?.dueCount(in: deck, at: now) ?? 0, cardCount: deck.cards.count, deckIDs: [deck.id]
            )
        }

        var rows: [Row] = []
        func visit(_ subject: Subject, indent: Int) {
            let inside = tree.decks(in: subject.id, among: decks)
            let ids = inside.map(\.id)
            rows.append(Row(
                kind: .subject(subject.id), name: subject.name, color: subject.color, indent: indent,
                tick: tick(for: ids), isEnabled: !inside.isEmpty,
                dueCount: inside.reduce(0) { $0 + (playback[$1.id]?.dueCount(in: $1, at: now) ?? 0) },
                cardCount: inside.reduce(0) { $0 + $1.cards.count }, deckIDs: ids
            ))
            for child in tree.children(of: subject.id) { visit(child, indent: indent + 1) }
            for deck in decks where deck.subjectID == subject.id { rows.append(deckRow(deck, indent: indent + 1)) }
        }
        for top in subjects where top.parentID == nil || !known.contains(top.parentID!) { visit(top, indent: 0) }
        for deck in decks where deck.subjectID == nil || !known.contains(deck.subjectID!) { rows.append(deckRow(deck, indent: 0)) }
        return rows
    }

    /// What a click on a row's tick does: a fully ticked row clears everything inside it; a clear or
    /// partly ticked one ticks everything inside it.
    static func toggled(_ row: Row, in ticked: Set<Deck.ID>) -> Set<Deck.ID> {
        guard row.isEnabled else { return ticked }
        var result = ticked
        if row.tick == .on {
            result.subtract(row.deckIDs)
        } else {
            result.formUnion(row.deckIDs)
        }
        return result
    }
}

extension ReviewSetup {
    /// A setup with these decks ticked, however they were chosen.
    init(ticking ids: Set<Deck.ID>, minutes: Int = ReviewRun.defaultMinutes) {
        self.init(startingWith: nil, minutes: minutes)
        ticked = ids
    }

    /// The decks that are still in the library; ids of ones deleted since are dropped, quietly.
    func droppingMissing(from decks: [Deck]) -> ReviewSetup {
        var result = self
        result.ticked = ticked.intersection(Set(decks.map(\.id)))
        return result
    }

    /// "<Current subject>": every deck inside a subject, sub-subjects too.
    mutating func tickDecks(in subjectID: Subject.ID, subjects: [Subject], decks: [Deck]) {
        ticked = Set(SubjectTree(subjects).decks(in: subjectID, among: decks).map(\.id))
    }

    /// What the sheet starts with: the mix ticked last time in this launch when it includes the deck you
    /// came from, otherwise just that deck. Decks that no longer exist are left out.
    static func startingTicked(remembered: Set<Deck.ID>, deckID: Deck.ID?, existing: Set<Deck.ID>) -> Set<Deck.ID> {
        let still = remembered.intersection(existing)
        guard let deckID, existing.contains(deckID) else { return still }
        return still.contains(deckID) ? still : [deckID]
    }
}

extension LibraryOutline {
    /// The decks that choosing these rows in the sidebar means: a deck is itself, a subject is every deck
    /// inside it, sub-subjects included. Each once.
    static func deckIDs(for items: Set<LibraryItem>, subjects: [Subject], decks: [Deck]) -> Set<Deck.ID> {
        let tree = SubjectTree(subjects)
        var ids = Set<Deck.ID>()
        for item in items {
            switch item {
            case .deck(let id):
                if decks.contains(where: { $0.id == id }) { ids.insert(id) }
            case .subject(let id):
                ids.formUnion(tree.decks(in: id, among: decks).map(\.id))
            }
        }
        return ids
    }

    /// The rows from one to another, both included, among those that can be chosen (headers don't count),
    /// for Shift-click. In the order the sidebar shows them whichever end was clicked first.
    static func range(from anchor: LibrarySelection, to end: LibrarySelection, in rows: [Row]) -> [LibrarySelection] {
        let selectable = rows.compactMap(\.selection)
        guard let a = selectable.firstIndex(of: anchor), let b = selectable.firstIndex(of: end) else { return [end] }
        return Array(selectable[min(a, b)...max(a, b)])
    }
}

extension LibraryOutline {
    /// "Review 3 decks", on the button that appears when several rows are chosen in the sidebar.
    static func reviewTitle(deckCount: Int) -> String {
        "Review \(deckCount) \(deckCount == 1 ? "deck" : "decks")"
    }
}

extension LibrarySelection {
    /// The same thing as something that can be dragged or chosen along with others.
    var item: LibraryItem {
        switch self {
        case .deck(let id): .deck(id)
        case .subject(let id): .subject(id)
        }
    }
}

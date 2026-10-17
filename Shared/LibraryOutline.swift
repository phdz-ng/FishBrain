import Foundation

/// What the main window is showing from the library: a deck or a subject's page.
enum LibrarySelection: Hashable, Sendable {
    case deck(Deck.ID)
    case subject(Subject.ID)
}

/// The sidebar's rows, worked out from subjects, decks and which subjects are expanded. Pure, with no
/// UI, like `DeckSelection`.
///
/// The sidebar never goes more than one indent deep. A top-level subject expands to show its
/// sub-subjects and its decks; a sub-subject has a trailing › and opens as its own page instead of
/// expanding; anything deeper is reached from those pages.
struct LibraryOutline: Sendable {
    enum Header: String, Equatable, Sendable {
        case subjects = "Subjects"
        case decks = "Decks"
    }

    struct SubjectRow: Equatable, Identifiable, Sendable {
        var id: Subject.ID
        var name: String
        var color: DeckColor
        /// 0 for a top-level subject, 1 inside one.
        var indent: Int
        /// Cards in everything inside, sub-subjects included.
        var cardCount: Int
        var dueCount: Int
        /// Only a top-level subject expands here.
        var isExpandable: Bool
        var isExpanded: Bool
        /// A sub-subject: › at the end, and it opens as a page.
        var opensPage: Bool
        var isSelected: Bool
        /// A deeper page (or a deck inside one) is open and this is the nearest row that can be shown for it.
        var isMarked: Bool
        /// Chosen along with others (⌘-click or Shift-click), for "Review N decks"; not the page that is open.
        var isPicked = false

        /// "Grammar, subject, 52 cards, 5 due"
        var accessibilityText: String {
            var text = "\(name), subject, \(cardCount) \(cardCount == 1 ? "card" : "cards")"
            if dueCount > 0 { text += ", \(dueCount) due" }
            return text
        }
    }

    struct DeckRow: Equatable, Identifiable, Sendable {
        var id: Deck.ID
        var name: String
        var color: DeckColor
        var cardCount: Int
        /// 0 for a loose deck, 1 inside a subject.
        var indent: Int
        var isSelected: Bool
        var isPicked = false
    }

    enum Row: Equatable, Identifiable, Sendable {
        case header(Header)
        case subject(SubjectRow)
        case deck(DeckRow)

        var id: String {
            switch self {
            case .header(let header): "header-\(header.rawValue)"
            case .subject(let row): "subject-\(row.id.uuidString)"
            case .deck(let row): "deck-\(row.id.uuidString)"
            }
        }

        /// What choosing the row selects; nil for a header.
        var selection: LibrarySelection? {
            switch self {
            case .header: nil
            case .subject(let row): .subject(row.id)
            case .deck(let row): .deck(row.id)
            }
        }
    }

    /// - Parameters:
    ///   - expanded: the top-level subjects that are open.
    ///   - selection: what the window is showing.
    ///   - playback: for the due counts; without it every count is zero.
    static func rows(
        subjects: [Subject],
        decks: [Deck],
        expanded: Set<Subject.ID>,
        selection: LibrarySelection?,
        playback: [Deck.ID: PlaybackState] = [:],
        now: Date = Date(),
        picked: Set<LibraryItem> = []
    ) -> [Row] {
        let tree = SubjectTree(subjects)
        func counts(in subject: Subject) -> (cards: Int, due: Int) {
            let inside = tree.decks(in: subject.id, among: decks)
            return (
                inside.reduce(0) { $0 + $1.cards.count },
                inside.reduce(0) { $0 + (playback[$1.id]?.dueCount(in: $1, at: now) ?? 0) }
            )
        }

        var rows: [Row] = []
        let topLevel = subjects.filter { $0.parentID == nil || tree.subject($0.parentID!) == nil }
        if !topLevel.isEmpty { rows.append(.header(.subjects)) }
        var visibleSubjects = Set<Subject.ID>()
        var visibleDecks = Set<Deck.ID>()
        var built: [Row] = []
        for subject in topLevel {
            let isExpanded = expanded.contains(subject.id)
            let c = counts(in: subject)
            visibleSubjects.insert(subject.id)
            built.append(.subject(SubjectRow(
                id: subject.id, name: subject.name, color: subject.color, indent: 0, cardCount: c.cards, dueCount: c.due,
                isExpandable: true, isExpanded: isExpanded, opensPage: false,
                isSelected: selection == .subject(subject.id), isMarked: false, isPicked: picked.contains(.subject(subject.id))
            )))
            guard isExpanded else { continue }
            for child in tree.children(of: subject.id) {
                let cc = counts(in: child)
                visibleSubjects.insert(child.id)
                built.append(.subject(SubjectRow(
                    id: child.id, name: child.name, color: child.color, indent: 1, cardCount: cc.cards, dueCount: cc.due,
                    isExpandable: false, isExpanded: false, opensPage: true,
                    isSelected: selection == .subject(child.id), isMarked: false, isPicked: picked.contains(.subject(child.id))
                )))
            }
            for deck in decks where deck.subjectID == subject.id {
                visibleDecks.insert(deck.id)
                built.append(.deck(DeckRow(
                    id: deck.id, name: deck.name, color: deck.color, cardCount: deck.cards.count, indent: 1,
                    isSelected: selection == .deck(deck.id), isPicked: picked.contains(.deck(deck.id))
                )))
            }
        }
        rows.append(contentsOf: built)

        // Decks with no subject (or whose subject is gone).
        let loose = decks.filter { $0.subjectID == nil || tree.subject($0.subjectID!) == nil }
        rows.append(.header(.decks))
        for deck in loose {
            rows.append(.deck(DeckRow(
                id: deck.id, name: deck.name, color: deck.color, cardCount: deck.cards.count, indent: 0,
                isSelected: selection == .deck(deck.id), isPicked: picked.contains(.deck(deck.id))
            )))
        }

        // Something deeper is open: mark the nearest row that is showing for it.
        if let marked = nearestVisibleSubject(for: selection, tree: tree, decks: decks, visibleSubjects: visibleSubjects, visibleDecks: visibleDecks) {
            for index in rows.indices {
                if case .subject(var row) = rows[index], row.id == marked {
                    row.isMarked = true
                    rows[index] = .subject(row)
                }
            }
        }
        return rows
    }

    /// The subject row to mark when the open page, or the open deck, has no row of its own in the list:
    /// the nearest of its ancestors that does.
    static func nearestVisibleSubject(
        for selection: LibrarySelection?, tree: SubjectTree, decks: [Deck],
        visibleSubjects: Set<Subject.ID>, visibleDecks: Set<Deck.ID>
    ) -> Subject.ID? {
        switch selection {
        case nil:
            return nil
        case .subject(let id)?:
            guard !visibleSubjects.contains(id) else { return nil }
            return tree.ancestors(of: id).first { visibleSubjects.contains($0.id) }?.id
        case .deck(let id)?:
            guard !visibleDecks.contains(id), let subjectID = decks.first(where: { $0.id == id })?.subjectID,
                  tree.subject(subjectID) != nil else { return nil }
            let chain = [subjectID] + tree.ancestors(of: subjectID).map(\.id)
            return chain.first { visibleSubjects.contains($0) }
        }
    }

    // MARK: Moving and revealing

    /// The top-level subject that has to be open for `selection` to show in the sidebar, if any.
    static func subjectToReveal(for selection: LibrarySelection, subjects: [Subject], decks: [Deck]) -> Subject.ID? {
        let tree = SubjectTree(subjects)
        let start: Subject.ID
        switch selection {
        case .subject(let id):
            guard tree.subject(id) != nil else { return nil }
            start = id
        case .deck(let id):
            guard let subjectID = decks.first(where: { $0.id == id })?.subjectID, tree.subject(subjectID) != nil else { return nil }
            start = subjectID
        }
        let root = tree.ancestors(of: start).last?.id ?? start
        // A top-level subject being selected doesn't need itself opened.
        if case .subject(let id) = selection, id == root { return nil }
        return root
    }

    /// `expanded` with whatever it takes for `selection` to be visible: a deep link or a search result for
    /// a deck inside a collapsed subject opens it.
    static func expanded(_ expanded: Set<Subject.ID>, revealing selection: LibrarySelection, subjects: [Subject], decks: [Deck]) -> Set<Subject.ID> {
        guard let root = subjectToReveal(for: selection, subjects: subjects, decks: decks) else { return expanded }
        return expanded.union([root])
    }

    /// The row `step` rows from `selection` among those that can be chosen (headers are skipped), stopping
    /// at the ends. With nothing selected, down picks the first and up the last.
    static func neighbor(of selection: LibrarySelection?, in rows: [Row], step: Int) -> LibrarySelection? {
        let selectable = rows.compactMap(\.selection)
        guard !selectable.isEmpty else { return nil }
        let current = selection.flatMap { selectable.firstIndex(of: $0) } ?? (step > 0 ? -1 : selectable.count)
        return selectable[min(max(current + step, 0), selectable.count - 1)]
    }
}

/// The "+ New" menu's choices for where the window is.
enum NewMenu {
    enum Action: Equatable, Sendable {
        case newDeck
        case newSubject
        case newDeckIn(Subject.ID)
        case newSubjectIn(Subject.ID)
        /// Opens the Import sheet; the sidebar's menu ends with it.
        case importFile
    }

    struct Item: Equatable, Sendable {
        var action: Action
        var title: String
        /// "⌘N"
        var shortcut: String?
        var isEnabled = true
        /// Why it is off.
        var disabledReason: String?
    }

    /// New Deck and New Subject, then "in <subject>" versions when a subject is open (or holds the open
    /// deck). A new subject goes at most three levels down: at the third level it is off, and the reason
    /// names the parent to use instead.
    static func items(in subjectID: Subject.ID?, tree: SubjectTree) -> [Item] {
        var items = [
            Item(action: .newDeck, title: "New Deck", shortcut: "⌘N"),
            Item(action: .newSubject, title: "New Subject", shortcut: "⇧⌘N"),
        ]
        if let subjectID, let subject = tree.subject(subjectID) {
            items.append(Item(action: .newDeckIn(subjectID), title: "New Deck in \(subject.name)"))
            items.append(subjectItem(in: subject, tree: tree))
        }
        return items
    }

    /// "Import…", below the New items in the sidebar's menu.
    static let importItem = Item(action: .importFile, title: "Import…", shortcut: "⇧⌘I")

    /// "New Subject in Grammar", or the disabled one that points at Grammar's parent.
    static func subjectItem(in subject: Subject, tree: SubjectTree) -> Item {
        var item = Item(action: .newSubjectIn(subject.id), title: "New Subject in \(subject.name)")
        if !tree.canAdd(under: subject.id) {
            item.isEnabled = false
            let parent = tree.ancestors(of: subject.id).first?.name
            item.disabledReason = parent.map { "Three levels is the most. Pick New Subject in \($0) instead." }
                ?? "Three levels is the most."
        }
        return item
    }
}

/// How a set of cards stands, for the stacked bar and the line under it on a tile.
struct StatusBreakdown: Equatable, Sendable {
    /// Cards whose time has come. A due card is also counted in `learning` or `young`.
    var due = 0
    var new = 0
    var learning = 0
    /// Learned and coming back before 21 days.
    var young = 0
    var mastered = 0

    var total: Int { new + learning + young + mastered }

    init() {}

    init(cards: [Card], state: PlaybackState?, now: Date) {
        for card in cards {
            let review = state?.review(for: card.id)
            switch CardStatus(review, at: now) {
            case .new: new += 1
            case .learning: learning += 1
            case .dueNow:
                due += 1
                if review?.reps == 0 { learning += 1 } else { young += 1 }
            case .upcoming: young += 1
            case .mastered: mastered += 1
            }
        }
    }

    static func + (lhs: StatusBreakdown, rhs: StatusBreakdown) -> StatusBreakdown {
        var sum = lhs
        sum.due += rhs.due
        sum.new += rhs.new
        sum.learning += rhs.learning
        sum.young += rhs.young
        sum.mastered += rhs.mastered
        return sum
    }

    enum Segment: Equatable, Sendable { case mastered, young, learning, new }

    /// The bar's parts in order, as shares of the whole (they add up to 1; none for an empty set).
    var segments: [(segment: Segment, fraction: Double)] {
        guard total > 0 else { return [] }
        return [(Segment.mastered, mastered), (.young, young), (.learning, learning), (.new, new)].map {
            ($0.0, Double($0.1) / Double(total))
        }
    }

    /// "9 due · 22 mastered · 12 new" or "Caught up · 4 mastered · 12 new"; zero parts are left out.
    var summaryText: String {
        guard total > 0 else { return "No cards yet" }
        var parts = [due > 0 ? "\(due) due" : "Caught up"]
        if mastered > 0 { parts.append("\(mastered) mastered") }
        if new > 0 { parts.append("\(new) new") }
        return parts.joined(separator: " · ")
    }
}

/// What a subject holds, in the words its page and its tile use.
struct SubjectSummary: Equatable, Sendable {
    /// Directly inside.
    var subjectCount: Int
    var deckCount: Int
    /// At any depth.
    var allSubjectCount: Int
    var allDeckCount: Int
    var cardCount: Int
    var dueCount: Int
    var breakdown: StatusBreakdown

    init(subject id: Subject.ID, tree: SubjectTree, decks: [Deck], playback: [Deck.ID: PlaybackState], now: Date) {
        subjectCount = tree.children(of: id).count
        deckCount = decks.filter { $0.subjectID == id }.count
        allSubjectCount = tree.descendants(of: id).count
        let inside = tree.decks(in: id, among: decks)
        allDeckCount = inside.count
        cardCount = inside.reduce(0) { $0 + $1.cards.count }
        let breakdown = inside.reduce(StatusBreakdown()) {
            $0 + StatusBreakdown(cards: $1.cards, state: playback[$1.id], now: now)
        }
        self.breakdown = breakdown
        dueCount = breakdown.due
    }

    var isEmpty: Bool { subjectCount == 0 && deckCount == 0 }

    /// Whether a button that goes through the cards in this subject is on, and if not, why.
    enum Availability: Equatable, Sendable {
        case enabled
        case disabled(String)

        var isEnabled: Bool { self == .enabled }
        var reason: String? {
            if case .disabled(let reason) = self { return reason }
            return nil
        }
    }

    /// Learn all and Review… both need something to go through: a deck, with cards in it.
    var cardsAvailability: Availability {
        if allDeckCount == 0 { return .disabled("There are no decks in this subject yet.") }
        if cardCount == 0 { return .disabled("There are no cards in this subject yet.") }
        return .enabled
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// "1 subject and 2 decks inside · 126 cards in all, 14 due", or for a subject with only decks
    /// "2 decks · 52 cards, 5 due".
    var pageSubtitle: String {
        if isEmpty { return "Nothing inside yet" }
        let due = dueCount > 0 ? ", \(dueCount) due" : ""
        if subjectCount > 0 {
            let inside = deckCount > 0
                ? "\(Self.count(subjectCount, "subject")) and \(Self.count(deckCount, "deck")) inside"
                : "\(Self.count(subjectCount, "subject")) inside"
            return "\(inside) · \(Self.count(cardCount, "card")) in all\(due)"
        }
        return "\(Self.count(deckCount, "deck")) · \(Self.count(cardCount, "card"))\(due)"
    }

    /// "1 subject · 2 decks · 52 cards" (everything inside, at any depth).
    var tileSubtitle: String {
        var parts: [String] = []
        if allSubjectCount > 0 { parts.append(Self.count(allSubjectCount, "subject")) }
        if allDeckCount > 0 { parts.append(Self.count(allDeckCount, "deck")) }
        parts.append(Self.count(cardCount, "card"))
        return parts.joined(separator: " · ")
    }

    /// "Grammar, subject, 52 cards, 5 due"
    func accessibilityText(name: String) -> String {
        var text = "\(name), subject, \(Self.count(cardCount, "card"))"
        if dueCount > 0 { text += ", \(dueCount) due" }
        return text
    }
}

import Foundation

/// A deck or a subject, as something that can be dragged or moved.
enum LibraryItem: Hashable, Sendable {
    case deck(Deck.ID)
    case subject(Subject.ID)
}

/// Somewhere in the sidebar an item can be dropped.
enum DropTarget: Hashable, Sendable {
    /// Onto a subject: file it there.
    case subject(Subject.ID)
    /// Onto the "Subjects" heading: a subject becomes top level.
    case subjectsHeading
    /// Onto the "Decks" heading: a deck becomes a loose deck.
    case decksHeading
}

/// The rules for moving decks and subjects about, with no UI: whether a drop is allowed and why not,
/// where "Move to…" may offer, and what deleting a subject says and leaves selected.
enum LibraryMove {
    enum Verdict: Equatable, Sendable {
        case allowed
        /// Refused, with a short reason for the tooltip.
        case refused(String)

        var isAllowed: Bool { self == .allowed }
        var reason: String? {
            if case .refused(let reason) = self { return reason }
            return nil
        }
    }

    // MARK: Drops

    /// Whether `item` may be dropped on `target`, with the library as it is. A subject can't go into
    /// itself or anything it holds, or where it, with all it already holds, would be deeper than
    /// `Subject.maxDepth`. Putting something where it already is counts as refused too: nothing would
    /// change.
    static func verdict(moving item: LibraryItem, to target: DropTarget, subjects: [Subject], decks: [Deck]) -> Verdict {
        let tree = SubjectTree(subjects)
        switch (item, target) {
        case (.deck(let id), .subject(let subjectID)):
            guard let deck = decks.first(where: { $0.id == id }), let subject = tree.subject(subjectID) else {
                return .refused("That isn't available any more.")
            }
            return deck.subjectID == subjectID ? .refused("Already in \(subject.name).") : .allowed

        case (.deck(let id), .decksHeading):
            guard let deck = decks.first(where: { $0.id == id }) else { return .refused("That isn't available any more.") }
            return deck.subjectID == nil ? .refused("Already a loose deck.") : .allowed

        case (.deck, .subjectsHeading):
            return .refused("A deck goes in a subject, or stays loose.")

        case (.subject(let id), .subject(let parentID)):
            guard let subject = tree.subject(id), let parent = tree.subject(parentID) else {
                return .refused("That isn't available any more.")
            }
            if id == parentID { return .refused("A subject can't go inside itself.") }
            if tree.descendants(of: id).contains(where: { $0.id == parentID }) {
                return .refused("A subject can't go inside what it holds.")
            }
            if subject.parentID == parentID { return .refused("Already in \(parent.name).") }
            return tree.canMove(id, into: parentID) ? .allowed : .refused("Three levels is the most.")

        case (.subject(let id), .subjectsHeading):
            guard let subject = tree.subject(id) else { return .refused("That isn't available any more.") }
            if subject.parentID == nil { return .refused("Already at the top level.") }
            return tree.canMove(id, into: nil) ? .allowed : .refused("Three levels is the most.")

        case (.subject, .decksHeading):
            return .refused("A subject can't become a deck.")
        }
    }

    // MARK: Move to…

    /// A place in the "Move to…" submenu.
    struct Destination: Equatable, Identifiable, Sendable {
        /// The subject; nil for the top level (or "no subject", for a deck).
        var subjectID: Subject.ID?
        var title: String
        /// The item can be moved here. False for a subject that is only in the list to reach one inside it.
        var isTarget: Bool
        var children: [Destination]

        var id: String { subjectID?.uuidString ?? "top" }
    }

    /// Where an item may go: "no subject" (or the top level, for a subject), when that is a move at all,
    /// and the tree of subjects it may go in.
    struct Destinations: Equatable, Sendable {
        var unfile: Destination?
        var subjects: [Destination]

        var isEmpty: Bool { unfile == nil && subjects.isEmpty }
        static let none = Destinations(unfile: nil, subjects: [])
    }

    /// The legal places for an item, as a tree. Illegal ones are left out, not greyed: nothing in it
    /// can be refused.
    static func destinations(for item: LibraryItem, subjects: [Subject], decks: [Deck]) -> Destinations {
        let tree = SubjectTree(subjects)
        let unfileTarget: DropTarget = {
            switch item {
            case .deck: .decksHeading
            case .subject: .subjectsHeading
            }
        }()
        var unfile: Destination?
        if verdict(moving: item, to: unfileTarget, subjects: subjects, decks: decks).isAllowed {
            switch item {
            case .deck: unfile = Destination(subjectID: nil, title: "No subject", isTarget: true, children: [])
            case .subject: unfile = Destination(subjectID: nil, title: "Top level", isTarget: true, children: [])
            }
        }

        // A subject can't go inside itself or what it holds, so those never appear.
        var excluded: Set<Subject.ID> = []
        if case .subject(let id) = item { excluded = tree.subjectIDs(in: id) }

        func node(_ subject: Subject) -> Destination? {
            guard !excluded.contains(subject.id) else { return nil }
            let children = tree.children(of: subject.id).compactMap(node)
            let isTarget = verdict(moving: item, to: .subject(subject.id), subjects: subjects, decks: decks).isAllowed
            guard isTarget || !children.isEmpty else { return nil }
            return Destination(subjectID: subject.id, title: subject.name, isTarget: isTarget, children: children)
        }
        return Destinations(
            unfile: unfile,
            subjects: subjects.filter { $0.parentID == nil || tree.subject($0.parentID!) == nil }.compactMap(node)
        )
    }

    // MARK: Deleting a subject

    /// What the confirmation for deleting a subject says: what is inside it, and the two ways to go on.
    struct DeletionPlan: Equatable, Sendable {
        var subject: Subject
        /// Sub-subjects, at any depth.
        var subjectCount: Int
        var deckCount: Int
        var cardCount: Int

        init(subject: Subject, subjects: [Subject], decks: [Deck]) {
            self.subject = subject
            let tree = SubjectTree(subjects)
            subjectCount = tree.descendants(of: subject.id).count
            let inside = tree.decks(in: subject.id, among: decks)
            deckCount = inside.count
            cardCount = inside.reduce(0) { $0 + $1.cards.count }
        }

        /// Nothing in it: it is deleted with a plain confirmation.
        var isEmpty: Bool { subjectCount == 0 && deckCount == 0 }

        var title: String { "Delete “\(subject.name)”?" }

        /// "It holds 1 subject, 2 decks and 52 cards."
        var message: String {
            if isEmpty { return "This subject is empty." }
            return "It holds \(contents)."
        }

        /// The default: nothing is lost.
        static let moveUpTitle = "Move its contents up"

        /// "Delete subject and its 2 decks and 52 cards" (the destructive choice).
        var deleteAllTitle: String { "Delete subject and its \(contents)" }

        private var contents: String {
            func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
            var parts: [String] = []
            if subjectCount > 0 { parts.append(count(subjectCount, "subject")) }
            if deckCount > 0 { parts.append(count(deckCount, "deck")) }
            parts.append(count(cardCount, "card"))
            if parts.count == 1 { return parts[0] }
            return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    /// What is selected after a subject goes: the parent (or the first row, for a top-level one) when the
    /// open subject was deleted, or, if its contents went too, a deck or subject inside it was open.
    enum SelectionAfterDelete: Equatable, Sendable {
        case unchanged
        case select(LibrarySelection)
        case firstRow
    }

    static func selectionAfterDeleting(
        _ subject: Subject, deletingContents: Bool, current: LibrarySelection?, subjects: [Subject], decks: [Deck]
    ) -> SelectionAfterDelete {
        let tree = SubjectTree(subjects)
        let inside = tree.subjectIDs(in: subject.id)
        let isGone: Bool
        switch current {
        case .subject(let id)?:
            // The subject itself always goes; those inside only go with it.
            isGone = id == subject.id || (deletingContents && inside.contains(id))
        case .deck(let id)?:
            isGone = deletingContents && (decks.first { $0.id == id }?.subjectID.map(inside.contains) ?? false)
        case nil:
            isGone = false
        }
        guard isGone else { return .unchanged }
        if let parent = subject.parentID, tree.subject(parent) != nil { return .select(.subject(parent)) }
        return .firstRow
    }
}

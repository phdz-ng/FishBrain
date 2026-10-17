import Foundation

/// How a deck's place in the subjects is written: "Spanish › Grammar › Verbs". One formatter, used
/// wherever decks are listed (search results, the notch's deck picker, the widget's deck choice), so a
/// path reads the same everywhere. Lives in `Shared/` so the widget extension can use it.
enum SubjectPath {
    static let separator = " › "
    /// A name longer than this is shortened in the middle, so a path stays one line.
    static let maxNameLength = 24

    /// "Intermediate Sp…nish verbs" style: the start and the end are kept, since both often tell names
    /// apart ("Spanish A1 verbs", "Spanish A2 verbs").
    static func middleTruncated(_ text: String, to limit: Int = maxNameLength) -> String {
        let characters = Array(text)
        guard limit >= 3, characters.count > limit else { return text }
        let keep = limit - 1 // one place for the ellipsis
        let head = (keep + 1) / 2
        let tail = keep - head
        return String(characters.prefix(head)) + "…" + String(characters.suffix(tail))
    }

    /// The names of the subjects a subject is inside, outermost first, ending with the subject itself.
    /// Empty for no subject, or one that isn't there.
    static func names(of subjectID: Subject.ID?, in subjects: [Subject]) -> [String] {
        guard let subjectID else { return [] }
        let tree = SubjectTree(subjects)
        guard let subject = tree.subject(subjectID) else { return [] }
        return (tree.ancestors(of: subjectID).reversed() + [subject]).map(\.name)
    }

    /// "Spanish › Grammar" for a subject; nil for no subject (a loose deck).
    static func text(of subjectID: Subject.ID?, in subjects: [Subject], limit: Int = maxNameLength) -> String? {
        let names = names(of: subjectID, in: subjects)
        guard !names.isEmpty else { return nil }
        return names.map { middleTruncated($0, to: limit) }.joined(separator: separator)
    }

    /// "Spanish › Grammar › Regular verbs": where a deck is, ending with the deck's own name. A loose deck
    /// is just its name.
    static func text(for deck: Deck, in subjects: [Subject], limit: Int = maxNameLength) -> String {
        let names = names(of: deck.subjectID, in: subjects) + [deck.name]
        return names.map { middleTruncated($0, to: limit) }.joined(separator: separator)
    }
}

/// The decks as the notch's picker groups them: under the path of the subject they are filed in, then
/// the loose ones last (as the sidebar lists Subjects before Decks).
struct DeckPickerSection: Equatable, Sendable {
    /// "Spanish › Grammar", or "Decks" for the loose ones; nil when there are no subjects at all and the
    /// list is just the decks.
    var title: String?
    var decks: [Deck]
}

enum DeckPicker {
    static let looseTitle = "Decks"

    static func sections(decks: [Deck], subjects: [Subject]) -> [DeckPickerSection] {
        let tree = SubjectTree(subjects)
        let known = Set(subjects.map(\.id))
        let loose = decks.filter { $0.subjectID.map { !known.contains($0) } ?? true }
        guard !subjects.isEmpty else { return decks.isEmpty ? [] : [DeckPickerSection(title: nil, decks: decks)] }

        var sections: [DeckPickerSection] = []
        // Subjects top-down in the order the sidebar shows them; ones holding no deck directly are skipped.
        func visit(_ subject: Subject) {
            let own = decks.filter { $0.subjectID == subject.id }
            if !own.isEmpty {
                sections.append(DeckPickerSection(title: SubjectPath.text(of: subject.id, in: subjects), decks: own))
            }
            for child in tree.children(of: subject.id) { visit(child) }
        }
        for top in subjects where top.parentID == nil || tree.subject(top.parentID!) == nil { visit(top) }
        if !loose.isEmpty { sections.append(DeckPickerSection(title: looseTitle, decks: loose)) }
        return sections
    }
}

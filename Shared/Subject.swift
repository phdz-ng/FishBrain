import Foundation
import OSLog

/// A group of decks (and of other subjects), like "Spanish" holding "Grammar" holding "Verbs". Subjects
/// and decks are two flat arrays in the library file; a subject says where it sits through `parentID`
/// and a deck through `Deck.subjectID`, so everything that reads decks (search, the widget, the notch,
/// playback) keeps working as it did.
struct Subject: Identifiable, Hashable, Codable, Sendable {
    /// How many subject levels may be nested: a subject, in a subject, in a subject. One constant, and
    /// nothing is stored that depends on it, so raising it later needs no migration.
    static let maxDepth = 3

    var id: UUID
    var name: String
    var color: DeckColor
    /// The subject this one is inside; nil is the top level.
    var parentID: UUID?

    init(id: UUID = UUID(), name: String, color: DeckColor = .accent, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.parentID = parentID
    }

    /// A name is trimmed and not blank; nil for one that is. The same name may appear in different
    /// subjects ("Verbs" in Spanish and in French).
    static func cleanName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The subjects as a tree, and the rules that keep it a tree of at most `Subject.maxDepth` levels. Pure
/// and cycle-safe: a library that was damaged outside the app answers these questions without looping,
/// and `Library.repaired()` puts it right.
struct SubjectTree: Equatable, Sendable {
    let subjects: [Subject]
    private let byID: [Subject.ID: Subject]

    init(_ subjects: [Subject]) {
        self.subjects = subjects
        // A duplicated id keeps its first appearance.
        byID = Dictionary(subjects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func subject(_ id: Subject.ID) -> Subject? { byID[id] }

    /// The subjects directly inside `parentID` (the top level for nil), in array order.
    func children(of parentID: Subject.ID?) -> [Subject] {
        subjects.filter { $0.parentID == parentID }
    }

    /// 1 for a top-level subject, 2 for one inside it, and so on. Nil for an unknown subject, or one
    /// caught in a cycle.
    func depth(of id: Subject.ID) -> Int? {
        guard byID[id] != nil else { return nil }
        var depth = 1
        var visited: Set<Subject.ID> = [id]
        var current = byID[id]?.parentID
        while let parent = current {
            guard byID[parent] != nil else { return depth } // a missing parent: as good as the top
            guard visited.insert(parent).inserted else { return nil }
            depth += 1
            current = byID[parent]?.parentID
        }
        return depth
    }

    /// The subjects above this one, nearest first. Stops at a missing parent or a repeat.
    func ancestors(of id: Subject.ID) -> [Subject] {
        var result: [Subject] = []
        var visited: Set<Subject.ID> = [id]
        var current = byID[id]?.parentID
        while let parent = current, let subject = byID[parent], visited.insert(parent).inserted {
            result.append(subject)
            current = subject.parentID
        }
        return result
    }

    /// Every subject below this one, at any depth, in array order.
    func descendants(of id: Subject.ID) -> [Subject] {
        var inside: Set<Subject.ID> = [id]
        var changed = true
        // Repeated passes in array order: cheap, and safe against cycles because a subject is added once.
        while changed {
            changed = false
            for subject in subjects where !inside.contains(subject.id) {
                if let parent = subject.parentID, inside.contains(parent) {
                    inside.insert(subject.id)
                    changed = true
                }
            }
        }
        inside.remove(id)
        return subjects.filter { inside.contains($0.id) }
    }

    /// The levels this subject holds counting itself: 1 for one with nothing inside it.
    func height(of id: Subject.ID) -> Int {
        guard byID[id] != nil else { return 0 }
        var best = 1
        var level: [Subject.ID] = [id]
        var seen: Set<Subject.ID> = [id]
        var depth = 1
        while true {
            let next = subjects.filter { subject in
                guard let parent = subject.parentID else { return false }
                return level.contains(parent) && !seen.contains(subject.id)
            }.map(\.id)
            guard !next.isEmpty else { return best }
            depth += 1
            best = depth
            seen.formUnion(next)
            level = next
        }
    }

    /// Whether a new subject may go inside `parentID` (or at the top level, for nil).
    func canAdd(under parentID: Subject.ID?) -> Bool {
        guard let parentID else { return true }
        guard let depth = depth(of: parentID) else { return false }
        return depth + 1 <= Subject.maxDepth
    }

    /// Whether `id` may go inside `parentID` (nil is the top level). Not into itself or into anything it
    /// holds, and not where it, with everything already inside it, would end up deeper than the cap.
    func canMove(_ id: Subject.ID, into parentID: Subject.ID?) -> Bool {
        guard byID[id] != nil else { return false }
        guard let parentID else { return height(of: id) <= Subject.maxDepth }
        guard parentID != id, byID[parentID] != nil else { return false }
        if descendants(of: id).contains(where: { $0.id == parentID }) { return false }
        guard let parentDepth = depth(of: parentID) else { return false }
        return parentDepth + height(of: id) <= Subject.maxDepth
    }

    /// The id and, with `includingSubSubjects`, the ids of everything inside it.
    func subjectIDs(in id: Subject.ID, includingSubSubjects: Bool = true) -> Set<Subject.ID> {
        guard byID[id] != nil else { return [] }
        return includingSubSubjects ? Set(descendants(of: id).map(\.id)).union([id]) : [id]
    }

    /// The decks filed under a subject (and, by default, under its sub-subjects), in deck array order.
    func decks(in id: Subject.ID, among decks: [Deck], includingSubSubjects: Bool = true) -> [Deck] {
        let ids = subjectIDs(in: id, includingSubSubjects: includingSubSubjects)
        return decks.filter { deck in deck.subjectID.map(ids.contains) ?? false }
    }

    /// The decks in a subject, sub-subjects included, in the order the sidebar and the review sheet list
    /// them: each sub-subject's decks first (in the sub-subjects' own order), then the subject's own.
    func decksInOutlineOrder(of id: Subject.ID, among decks: [Deck]) -> [Deck] {
        guard byID[id] != nil else { return [] }
        var result: [Deck] = []
        var seen = Set<Subject.ID>()
        func visit(_ subjectID: Subject.ID) {
            guard seen.insert(subjectID).inserted else { return }
            for child in children(of: subjectID) { visit(child.id) }
            result.append(contentsOf: decks.filter { $0.subjectID == subjectID })
        }
        visit(id)
        return result
    }

    /// "Spanish › Grammar › Verbs", for showing where something is.
    func path(of id: Subject.ID, separator: String = " › ") -> String? {
        guard let subject = byID[id] else { return nil }
        return (ancestors(of: id).reversed() + [subject]).map(\.name).joined(separator: separator)
    }
}

/// The whole library: its subjects and its decks, both flat and in order.
struct Library: Equatable, Sendable {
    var subjects: [Subject] = []
    var decks: [Deck] = []

    init(subjects: [Subject] = [], decks: [Deck] = []) {
        self.subjects = subjects
        self.decks = decks
    }

    /// The library with anything inconsistent put right, and a line for each thing that was changed. It
    /// never drops a deck or a card, and never drops a subject that is only misplaced:
    ///
    /// - a subject whose id is used twice keeps its first appearance (the others had no decks of their own);
    /// - a subject whose parent is missing goes to the top level;
    /// - a cycle is cut by moving one of its subjects to the top level;
    /// - a subject deeper than `Subject.maxDepth` goes to the top level;
    /// - a deck filed under a subject that doesn't exist becomes a loose deck.
    func repaired() -> (library: Library, repairs: [String]) {
        var repairs: [String] = []
        var subjects: [Subject] = []
        var ids = Set<Subject.ID>()
        for subject in self.subjects {
            if ids.insert(subject.id).inserted {
                subjects.append(subject)
            } else {
                repairs.append("subject \(subject.id) was listed twice")
            }
        }

        for index in subjects.indices {
            if let parent = subjects[index].parentID, !ids.contains(parent) {
                repairs.append("subject \"\(subjects[index].name)\" was inside a missing subject; moved to the top level")
                subjects[index].parentID = nil
            }
        }

        // Cycles: while some subject has no depth, move the first such subject to the top level.
        while let index = subjects.indices.first(where: { SubjectTree(subjects).depth(of: subjects[$0].id) == nil }) {
            repairs.append("subject \"\(subjects[index].name)\" was part of a loop; moved to the top level")
            subjects[index].parentID = nil
        }

        // Too deep: the first subject past the cap goes to the top level, and the rest are looked at again.
        while let index = subjects.indices.first(where: { (SubjectTree(subjects).depth(of: subjects[$0].id) ?? 0) > Subject.maxDepth }) {
            repairs.append("subject \"\(subjects[index].name)\" was deeper than \(Subject.maxDepth) levels; moved to the top level")
            subjects[index].parentID = nil
        }

        var decks = self.decks
        for index in decks.indices {
            if let subjectID = decks[index].subjectID, !ids.contains(subjectID) {
                repairs.append("deck \"\(decks[index].name)\" was in a missing subject; made a loose deck")
                decks[index].subjectID = nil
            }
        }
        return (Library(subjects: subjects, decks: decks), repairs)
    }
}

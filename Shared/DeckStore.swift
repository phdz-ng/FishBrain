import Foundation
import OSLog
import SwiftUI
import WidgetKit

/// App-side observable library. Edits are saved after a short pause so typing doesn't hit the
/// disk on every keystroke, and each save asks WidgetKit to refresh the widget.
@MainActor
final class DeckStore: ObservableObject {
    @Published var decks: [Deck] {
        didSet { scheduleSave() }
    }
    /// Subjects, flat and in order; where each sits is its `parentID`, and decks say which they are in.
    @Published var subjects: [Subject] {
        didSet { scheduleSave() }
    }
    @Published private(set) var lastSaveError: Error?

    private let storage: DeckStorage
    /// The pictures on cards, in a folder next to `decks.json`.
    let imageStore: CardImageStore
    private let debounce: Duration
    private let onSaved: @MainActor () -> Void
    private let logger = Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "store")
    /// The in-flight debounced save; awaitable so tests don't need to sleep.
    private(set) var pendingSave: Task<Void, Never>?
    /// Where undo for moving and deleting decks and subjects goes. The window gives it its own, so
    /// Edit > Undo and ⌘Z work; with none, those changes simply aren't undoable.
    var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = Self.undoLevels }
    }
    static let undoLevels = 20
    /// Decks that deleting took out, one entry per delete, kept while undo could bring them back so their
    /// pictures aren't swept before then. Only kept where there is an undo manager to ask.
    private var recentlyRemovedDecks: [[Deck]] = []

    init(
        storage: DeckStorage = .shared(),
        debounce: Duration = .milliseconds(500),
        onSaved: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.storage = storage
        self.imageStore = CardImageStore.beside(storage.directory)
        self.debounce = debounce
        self.onSaved = onSaved
        let library = storage.loadLibrary()
        self.decks = library.decks
        self.subjects = library.subjects
        // Pictures left behind by a crash or an older edit. Only with a library to compare against: an
        // unreadable decks.json comes back empty, and that must never look like "no card uses any".
        if !decks.isEmpty { sweepImages() }
    }

    // MARK: Editing decks

    static let defaultDeckName = "New Deck"

    /// Appends a deck. Without a name it gets "New Deck", "New Deck 2", ... so new decks are
    /// easy to tell apart until the user renames them.
    @discardableResult
    func addDeck(name: String? = nil, color: DeckColor = .accent) -> Deck {
        let deck = Deck(name: name ?? uniqueDefaultName(), color: color)
        decks.append(deck)
        return deck
    }

    /// Appends a deck that is already built (the "Getting Started" deck).
    @discardableResult
    func add(_ deck: Deck) -> Deck {
        decks.append(deck)
        return deck
    }

    /// Returns false (and changes nothing) for an unknown deck or a blank name.
    @discardableResult
    func renameDeck(_ id: Deck.ID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = decks.firstIndex(where: { $0.id == id }) else { return false }
        if decks[index].name != trimmed {
            decks[index].name = trimmed
        }
        return true
    }

    func setColor(_ color: DeckColor, for id: Deck.ID) {
        guard let index = decks.firstIndex(where: { $0.id == id }), decks[index].color != color else { return }
        decks[index].color = color
    }

    /// Removes the deck and its cards; returns it so callers can report what was removed.
    @discardableResult
    func deleteDeck(_ id: Deck.ID) -> Deck? {
        guard let index = decks.firstIndex(where: { $0.id == id }) else { return nil }
        var removed: Deck?
        structural("Delete Deck") { removed = decks.remove(at: index) }
        return removed
    }

    // MARK: Subjects

    var subjectTree: SubjectTree { SubjectTree(subjects) }

    static let defaultSubjectName = "New Subject"

    /// Adds a subject (inside `parentID`, or at the top level). Nil, and nothing changes, for a blank
    /// name, an unknown parent, or one that would put it deeper than `Subject.maxDepth`.
    @discardableResult
    func addSubject(name: String? = nil, color: DeckColor = .accent, parentID: Subject.ID? = nil) -> Subject? {
        let tree = subjectTree
        guard tree.canAdd(under: parentID) else { return nil }
        let resolved: String
        if let name {
            guard let cleaned = Subject.cleanName(name) else { return nil }
            resolved = cleaned
        } else {
            resolved = uniqueDefaultSubjectName(under: parentID)
        }
        let subject = Subject(name: resolved, color: color, parentID: parentID)
        subjects.append(subject)
        return subject
    }

    /// Returns false (and changes nothing) for an unknown subject or a blank name.
    @discardableResult
    func renameSubject(_ id: Subject.ID, to name: String) -> Bool {
        guard let cleaned = Subject.cleanName(name), let index = subjects.firstIndex(where: { $0.id == id }) else { return false }
        if subjects[index].name != cleaned { subjects[index].name = cleaned }
        return true
    }

    func setColor(_ color: DeckColor, forSubject id: Subject.ID) {
        guard let index = subjects.firstIndex(where: { $0.id == id }), subjects[index].color != color else { return }
        subjects[index].color = color
    }

    /// Moves a subject, with everything in it, inside `parentID` (nil is the top level). It goes last
    /// among its new siblings. False, and nothing changes, if that isn't allowed: into itself, into
    /// something it holds, or deeper than `Subject.maxDepth` counting what it already holds.
    @discardableResult
    func moveSubject(_ id: Subject.ID, into parentID: Subject.ID?) -> Bool {
        guard subjectTree.canMove(id, into: parentID), let index = subjects.firstIndex(where: { $0.id == id }) else { return false }
        if subjects[index].parentID == parentID { return true }
        structural("Move Subject") {
            // One assignment, so nothing observing ever sees the subject missing.
            var reordered = subjects
            var subject = reordered.remove(at: index)
            subject.parentID = parentID
            reordered.append(subject)
            subjects = reordered
        }
        return true
    }

    /// Drag-to-reorder in the subject array, which is the order they are shown in.
    func reorderSubjects(from source: IndexSet, to destination: Int) {
        var reordered = subjects
        reordered.move(fromOffsets: source, toOffset: destination)
        guard reordered != subjects else { return }
        subjects = reordered
    }

    /// Files a deck under a subject, or makes it a loose deck with nil. Its id, cards and place in the deck
    /// array are untouched, so its schedule stays with it. False for an unknown deck or subject.
    @discardableResult
    func moveDeck(_ id: Deck.ID, to subjectID: Subject.ID?) -> Bool {
        guard let index = decks.firstIndex(where: { $0.id == id }) else { return false }
        if let subjectID, !subjects.contains(where: { $0.id == subjectID }) { return false }
        if decks[index].subjectID != subjectID {
            structural("Move Deck") { decks[index].subjectID = subjectID }
        }
        return true
    }

    /// Deletes a subject and keeps everything in it: its decks and sub-subjects move up one level (to the
    /// top level, for a top-level subject). Returns the subject, or nil if there was none.
    @discardableResult
    func deleteSubject(_ id: Subject.ID) -> Subject? {
        guard let index = subjects.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = subjects[index]
        structural("Delete Subject") {
            var remaining = subjects
            for i in remaining.indices where remaining[i].parentID == id { remaining[i].parentID = removed.parentID }
            remaining.removeAll { $0.id == id }
            var filed = decks
            for i in filed.indices where filed[i].subjectID == id { filed[i].subjectID = removed.parentID }
            // The decks first: they are never pointing at a subject that is already gone.
            if filed != decks { decks = filed }
            subjects = remaining
        }
        return removed
    }

    /// What `deleteSubjectAndContents` removed.
    struct RemovedSubjectContents: Equatable {
        var subjects: [Subject]
        var decks: [Deck]
        var cardCount: Int { decks.reduce(0) { $0 + $1.cards.count } }
    }

    /// The destructive choice: the subject, everything inside it and every deck filed there, with their
    /// cards. Returns what went, or nil if there was no such subject.
    @discardableResult
    func deleteSubjectAndContents(_ id: Subject.ID) -> RemovedSubjectContents? {
        let tree = subjectTree
        guard tree.subject(id) != nil else { return nil }
        let ids = tree.subjectIDs(in: id)
        let removedSubjects = subjects.filter { ids.contains($0.id) }
        let removedDecks = decks.filter { deck in deck.subjectID.map(ids.contains) ?? false }
        structural("Delete Subject") {
            subjects.removeAll { ids.contains($0.id) }
            let goneDecks = Set(removedDecks.map(\.id))
            decks.removeAll { goneDecks.contains($0.id) }
        }
        return RemovedSubjectContents(subjects: removedSubjects, decks: removedDecks)
    }

    // MARK: Undoing moves and deletes

    /// What a move or a delete changed: for each subject and deck whose place or presence differs, where
    /// it was and where it ended up. Applying either side puts those, and only those, back; edits made
    /// meanwhile to the same items (a rename, a card) are kept.
    private struct StructureChange {
        struct Place<Item> {
            var item: Item
            var index: Int
        }

        var subjectsBefore: [Subject.ID: Place<Subject>] = [:]
        var subjectsAfter: [Subject.ID: Place<Subject>] = [:]
        var decksBefore: [Deck.ID: Place<Deck>] = [:]
        var decksAfter: [Deck.ID: Place<Deck>] = [:]

        enum Side {
            case before, after
            var opposite: Side { self == .before ? .after : .before }
        }

        var isEmpty: Bool { subjectsBefore.isEmpty && subjectsAfter.isEmpty && decksBefore.isEmpty && decksAfter.isEmpty }

        init(beforeSubjects: [Subject], afterSubjects: [Subject], beforeDecks: [Deck], afterDecks: [Deck]) {
            let beforeS = Dictionary(uniqueKeysWithValues: beforeSubjects.enumerated().map { ($1.id, Place(item: $1, index: $0)) })
            let afterS = Dictionary(uniqueKeysWithValues: afterSubjects.enumerated().map { ($1.id, Place(item: $1, index: $0)) })
            for id in Set(beforeS.keys).union(afterS.keys) {
                let b = beforeS[id], a = afterS[id]
                // Only presence and parent matter: an index that merely shifted isn't a change.
                if b == nil || a == nil || b?.item.parentID != a?.item.parentID {
                    subjectsBefore[id] = b
                    subjectsAfter[id] = a
                }
            }
            let beforeD = Dictionary(uniqueKeysWithValues: beforeDecks.enumerated().map { ($1.id, Place(item: $1, index: $0)) })
            let afterD = Dictionary(uniqueKeysWithValues: afterDecks.enumerated().map { ($1.id, Place(item: $1, index: $0)) })
            for id in Set(beforeD.keys).union(afterD.keys) {
                let b = beforeD[id], a = afterD[id]
                if b == nil || a == nil || b?.item.subjectID != a?.item.subjectID {
                    decksBefore[id] = b
                    decksAfter[id] = a
                }
            }
        }
    }

    /// Runs a change to the structure and, if it did anything, makes it undoable.
    private func structural(_ name: String, _ change: () -> Void) {
        let beforeSubjects = subjects, beforeDecks = decks
        change()
        let record = StructureChange(
            beforeSubjects: beforeSubjects, afterSubjects: subjects, beforeDecks: beforeDecks, afterDecks: decks
        )
        guard !record.isEmpty else { return }
        let removed = record.decksBefore.filter { record.decksAfter[$0.key] == nil }.values.map(\.item)
        if !removed.isEmpty, undoManager != nil {
            recentlyRemovedDecks.append(removed)
            if recentlyRemovedDecks.count > Self.undoLevels {
                recentlyRemovedDecks.removeFirst(recentlyRemovedDecks.count - Self.undoLevels)
            }
        }
        registerUndo(name) { $0.apply(record, side: .before, name: name) }
    }

    private func registerUndo(_ name: String, _ undo: @escaping @MainActor (DeckStore) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { undo(target) } }
        if !undoManager.isUndoing, !undoManager.isRedoing { undoManager.setActionName(name) }
    }

    /// Puts the items a change touched into the state of one side. Registered while undoing, that is
    /// the redo, so each side leads to the other.
    private func apply(_ change: StructureChange, side: StructureChange.Side, name: String) {
        let targetSubjects = side == .before ? change.subjectsBefore : change.subjectsAfter
        let targetDecks = side == .before ? change.decksBefore : change.decksAfter
        let touchedSubjects = Set(change.subjectsBefore.keys).union(change.subjectsAfter.keys)
        let touchedDecks = Set(change.decksBefore.keys).union(change.decksAfter.keys)

        func restoredSubjects() -> [Subject] {
            let current = Dictionary(uniqueKeysWithValues: subjects.map { ($0.id, $0) })
            var result = subjects.filter { !touchedSubjects.contains($0.id) }
            for (id, place) in targetSubjects.sorted(by: { $0.value.index < $1.value.index }) {
                var item = current[id] ?? place.item
                item.parentID = place.item.parentID
                result.insert(item, at: min(place.index, result.count))
            }
            return result
        }
        func restoredDecks() -> [Deck] {
            let current = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })
            var result = decks.filter { !touchedDecks.contains($0.id) }
            for (id, place) in targetDecks.sorted(by: { $0.value.index < $1.value.index }) {
                var item = current[id] ?? place.item
                item.subjectID = place.item.subjectID
                result.insert(item, at: min(place.index, result.count))
            }
            return result
        }

        // Decks this takes out (undoing an import) may come back with redo: their pictures stay until
        // that can't happen.
        if undoManager != nil {
            let leaving = decks.filter { touchedDecks.contains($0.id) && targetDecks[$0.id] == nil }
            if !leaving.isEmpty {
                recentlyRemovedDecks.append(leaving)
                if recentlyRemovedDecks.count > Self.undoLevels {
                    recentlyRemovedDecks.removeFirst(recentlyRemovedDecks.count - Self.undoLevels)
                }
            }
        }

        // Subjects come back before the decks that point at them, and go after them.
        if side == .before {
            subjects = restoredSubjects()
            decks = restoredDecks()
        } else {
            decks = restoredDecks()
            subjects = restoredSubjects()
        }
        registerUndo(name) { $0.apply(change, side: side.opposite, name: name) }
    }

    private func uniqueDefaultSubjectName(under parentID: Subject.ID?) -> String {
        let taken = Set(subjects.filter { $0.parentID == parentID }.map(\.name))
        guard taken.contains(Self.defaultSubjectName) else { return Self.defaultSubjectName }
        var n = 2
        while taken.contains("\(Self.defaultSubjectName) \(n)") { n += 1 }
        return "\(Self.defaultSubjectName) \(n)"
    }

    // MARK: Editing cards

    /// Lookups and edits go by id, never by position, so a late edit from a row that was just
    /// deleted (or reordered) is a harmless no-op instead of an out-of-range crash.
    func card(_ cardID: Card.ID, in deckID: Deck.ID) -> Card? {
        decks.first { $0.id == deckID }?.cards.first { $0.id == cardID }
    }

    /// Appends an empty card to the end of the deck (the end of the rotation).
    @discardableResult
    func addCard(to deckID: Deck.ID, front: String = "", back: String = "") -> Card? {
        guard let deckIndex = decks.firstIndex(where: { $0.id == deckID }) else { return nil }
        let card = Card(front: front, back: back)
        decks[deckIndex].cards.append(card)
        return card
    }

    /// Appends many cards at once (one edit, so one save). Returns how many were added.
    @discardableResult
    func addCards(_ parsed: [ParsedCard], to deckID: Deck.ID) -> Int {
        guard !parsed.isEmpty, let deckIndex = decks.firstIndex(where: { $0.id == deckID }) else { return 0 }
        decks[deckIndex].cards.append(contentsOf: parsed.map { Card(front: $0.front, back: $0.back) })
        return parsed.count
    }

    /// Carries out an import: the new subjects and decks, and cards for decks that exist, as one undo
    /// step (⌘Z takes all of it back, ⇧⌘Z does it again). Returns false when there was nothing to add.
    @discardableResult
    func performImport(_ plan: CSVImportPlan) -> Bool {
        guard !plan.isEmpty else { return false }
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        structural("Import") {
            subjects.append(contentsOf: plan.newSubjects)
            decks.append(contentsOf: plan.newDecks)
        }
        let known = Set(decks.map(\.id))
        let additions = plan.additions.filter { known.contains($0.deckID) }
        if !additions.isEmpty { setCards(additions, present: true, name: "Import") }
        return true
    }

    /// Puts cards into decks, or takes the same ones out, registering the opposite for undo and redo.
    private func setCards(_ additions: [CSVImportPlan.Addition], present: Bool, name: String) {
        for addition in additions {
            guard let index = decks.firstIndex(where: { $0.id == addition.deckID }) else { continue }
            if present {
                let have = Set(decks[index].cards.map(\.id))
                decks[index].cards.append(contentsOf: addition.cards.filter { !have.contains($0.id) })
            } else {
                let ids = Set(addition.cards.map(\.id))
                decks[index].cards.removeAll { ids.contains($0.id) }
            }
        }
        registerUndo(name) { $0.setCards(additions, present: !present, name: name) }
    }

    func updateCard(_ cardID: Card.ID, in deckID: Deck.ID, _ change: (inout Card) -> Void) {
        guard let deckIndex = decks.firstIndex(where: { $0.id == deckID }),
              let cardIndex = decks[deckIndex].cards.firstIndex(where: { $0.id == cardID }) else { return }
        var card = decks[deckIndex].cards[cardIndex]
        change(&card)
        guard card != decks[deckIndex].cards[cardIndex] else { return }
        decks[deckIndex].cards[cardIndex] = card
    }

    // MARK: Pictures

    /// Puts a picture on one side of a card, replacing any there. The old files go at the next save.
    func setImage(_ image: CardImage?, on side: CardSide, for cardID: Card.ID, in deckID: Deck.ID) {
        updateCard(cardID, in: deckID) { $0.setImage(image, on: side) }
    }

    /// Sets what VoiceOver says for a picture; blank goes back to using the card's text.
    func setAltText(_ text: String, on side: CardSide, for cardID: Card.ID, in deckID: Deck.ID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        updateCard(cardID, in: deckID) { card in
            guard var image = card.image(on: side) else { return }
            image.altText = trimmed.isEmpty ? nil : trimmed
            card.setImage(image, on: side)
        }
    }

    /// Reads a picture from a file and puts it on a card. The decoding and scaling run off the main
    /// thread. Throws if the file isn't a picture. If the card was deleted meanwhile, nothing is attached
    /// and the files are cleaned up later.
    func addImage(contentsOf url: URL, on side: CardSide, for cardID: Card.ID, in deckID: Deck.ID) async throws {
        let store = imageStore
        let image = try await Task.detached { try store.add(contentsOf: url) }.value
        setImage(image, on: side, for: cardID, in: deckID)
    }

    func addImage(_ source: PictureSource, on side: CardSide, for cardID: Card.ID, in deckID: Deck.ID) async throws {
        switch source {
        case .file(let url): try await addImage(contentsOf: url, on: side, for: cardID, in: deckID)
        case .data(let data): try await addImage(data: data, on: side, for: cardID, in: deckID)
        }
    }

    /// The same for picture data, such as a picture pasted from the clipboard.
    func addImage(data: Data, on side: CardSide, for cardID: Card.ID, in deckID: Deck.ID) async throws {
        let store = imageStore
        let image = try await Task.detached { try store.add(data: data) }.value
        setImage(image, on: side, for: cardID, in: deckID)
    }

    /// Deletes picture files no card uses. Runs after every save, so a deleted card or deck, or a
    /// replaced picture, takes its files with it, and never before the card list that stops using them
    /// is on disk.
    ///
    /// Sweeps run one after another, each on the library as it was when it was asked for, so awaiting
    /// `pendingSweep` means every earlier sweep is done too.
    private func sweepImages() {
        var referenced = decks.imageFileNames
        // A deck that was just deleted may be undone: its pictures stay until it can't be.
        for removed in recentlyRemovedDecks { referenced.formUnion(removed.imageFileNames) }
        let store = imageStore
        let previous = pendingSweep
        pendingSweep = Task.detached(priority: .utility) {
            _ = await previous?.value
            return store.sweep(keeping: referenced)
        }
    }

    /// The latest picture cleanup, queued behind all earlier ones; awaitable so tests don't need to sleep.
    private(set) var pendingSweep: Task<Int, Never>?

    /// Waits until the library is on disk and the picture cleanup it triggered has finished,
    /// including any edit made while waiting. Doesn't write anything itself or shorten the debounce.
    func settled() async {
        while true {
            let save = pendingSave
            let sweep = pendingSweep
            await save?.value
            _ = await sweep?.value
            if pendingSave == save && pendingSweep == sweep { return }
        }
    }

    func deleteCards(_ cardIDs: Set<Card.ID>, in deckID: Deck.ID) {
        guard let deckIndex = decks.firstIndex(where: { $0.id == deckID }),
              decks[deckIndex].cards.contains(where: { cardIDs.contains($0.id) }) else { return }
        decks[deckIndex].cards.removeAll { cardIDs.contains($0.id) }
    }

    /// Drag-to-reorder. The array order is the rotation order.
    func moveCards(in deckID: Deck.ID, from source: IndexSet, to destination: Int) {
        guard let deckIndex = decks.firstIndex(where: { $0.id == deckID }) else { return }
        var cards = decks[deckIndex].cards
        cards.move(fromOffsets: source, toOffset: destination)
        guard cards != decks[deckIndex].cards else { return }
        decks[deckIndex].cards = cards
    }

    private func uniqueDefaultName() -> String {
        let taken = Set(decks.map(\.name))
        guard taken.contains(Self.defaultDeckName) else { return Self.defaultDeckName }
        var n = 2
        while taken.contains("\(Self.defaultDeckName) \(n)") { n += 1 }
        return "\(Self.defaultDeckName) \(n)"
    }

    /// Saves immediately, cancelling any pending debounced save. Call on app termination.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        write()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.write()
        }
    }

    private func write() {
        do {
            try storage.save(Library(subjects: subjects, decks: decks))
            lastSaveError = nil
            sweepImages()
            onSaved()
        } catch {
            lastSaveError = error
            logger.error("Save failed: \(error.localizedDescription)")
        }
    }
}

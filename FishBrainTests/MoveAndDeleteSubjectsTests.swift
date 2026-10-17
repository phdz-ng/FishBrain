import XCTest

/// Move, drag and delete subjects and decks (FLAS-64).
private struct Shelf {
    let spanish = Subject(name: "Spanish")
    let grammar: Subject
    let verbs: Subject
    let biology = Subject(name: "Biology")
    let cells: Subject
    let everyday: Deck, regular: Deck, irregular: Deck, loose: Deck, cellDeck: Deck

    init() {
        grammar = Subject(name: "Grammar", parentID: spanish.id)
        verbs = Subject(name: "Verbs", parentID: grammar.id)
        cells = Subject(name: "Cells", parentID: biology.id)
        func deck(_ name: String, _ n: Int, in subject: Subject?) -> Deck {
            Deck(name: name, cards: (1...n).map { Card(front: "\(name) \($0)", back: "b") }, subjectID: subject?.id)
        }
        everyday = deck("Everyday Spanish", 48, in: spanish)
        regular = deck("Regular verbs", 30, in: verbs)
        irregular = deck("Irregular verbs", 22, in: verbs)
        loose = deck("World Capitals", 60, in: nil)
        cellDeck = deck("Cell structure", 12, in: cells)
    }

    var subjects: [Subject] { [spanish, grammar, verbs, biology, cells] }
    var decks: [Deck] { [everyday, regular, irregular, loose, cellDeck] }

    func verdict(_ item: LibraryItem, _ target: DropTarget) -> LibraryMove.Verdict {
        LibraryMove.verdict(moving: item, to: target, subjects: subjects, decks: decks)
    }
}

final class DropRulesTests: XCTestCase {
    private let shelf = Shelf()

    func testADeckMayBeFiledUnderAnySubjectItIsNotAlreadyIn() {
        let s = shelf
        XCTAssertEqual(s.verdict(.deck(s.loose.id), .subject(s.spanish.id)), .allowed)
        XCTAssertEqual(s.verdict(.deck(s.loose.id), .subject(s.verbs.id)), .allowed, "a deck may sit at the third level")
        XCTAssertEqual(s.verdict(.deck(s.everyday.id), .subject(s.biology.id)), .allowed)
        XCTAssertEqual(s.verdict(.deck(s.everyday.id), .subject(s.spanish.id)), .refused("Already in Spanish."))
        XCTAssertFalse(s.verdict(.deck(UUID()), .subject(s.spanish.id)).isAllowed)
        XCTAssertFalse(s.verdict(.deck(s.loose.id), .subject(UUID())).isAllowed)
    }

    func testADeckDroppedOnTheDecksHeadingBecomesLooseOnlyIfItIsFiled() {
        let s = shelf
        XCTAssertEqual(s.verdict(.deck(s.everyday.id), .decksHeading), .allowed)
        XCTAssertEqual(s.verdict(.deck(s.loose.id), .decksHeading), .refused("Already a loose deck."))
    }

    func testADeckCannotBeDroppedOnTheSubjectsHeading() {
        let s = shelf
        XCTAssertFalse(s.verdict(.deck(s.everyday.id), .subjectsHeading).isAllowed)
        XCTAssertFalse(s.verdict(.deck(s.loose.id), .subjectsHeading).isAllowed)
    }

    func testASubjectMayGoIntoAnotherWhereItFits() {
        let s = shelf
        // Grammar (holding Verbs, two levels) under Biology (depth 1): 1 + 2 = 3.
        XCTAssertEqual(s.verdict(.subject(s.grammar.id), .subject(s.biology.id)), .allowed)
        // Cells (a leaf) into Verbs, the third level: a fourth.
        XCTAssertEqual(s.verdict(.subject(s.cells.id), .subject(s.verbs.id)), .refused("Three levels is the most."))
        // Cells into Grammar (depth 2) is the third level: fine.
        XCTAssertEqual(s.verdict(.subject(s.cells.id), .subject(s.grammar.id)), .allowed)
        // Spanish holds three levels, so it fits nowhere but the top.
        XCTAssertEqual(s.verdict(.subject(s.spanish.id), .subject(s.biology.id)), .refused("Three levels is the most."))
    }

    func testASubjectCannotGoIntoItselfOrWhatItHolds() {
        let s = shelf
        XCTAssertEqual(s.verdict(.subject(s.spanish.id), .subject(s.spanish.id)), .refused("A subject can't go inside itself."))
        XCTAssertEqual(s.verdict(.subject(s.spanish.id), .subject(s.grammar.id)), .refused("A subject can't go inside what it holds."))
        XCTAssertEqual(s.verdict(.subject(s.spanish.id), .subject(s.verbs.id)), .refused("A subject can't go inside what it holds."))
        XCTAssertEqual(s.verdict(.subject(s.grammar.id), .subject(s.verbs.id)), .refused("A subject can't go inside what it holds."))
    }

    func testASubjectDroppedWhereItAlreadyIsIsRefused() {
        let s = shelf
        XCTAssertEqual(s.verdict(.subject(s.grammar.id), .subject(s.spanish.id)), .refused("Already in Spanish."))
        XCTAssertEqual(s.verdict(.subject(s.spanish.id), .subjectsHeading), .refused("Already at the top level."))
    }

    func testASubjectDroppedOnSubjectsBecomesTopLevel() {
        let s = shelf
        XCTAssertEqual(s.verdict(.subject(s.grammar.id), .subjectsHeading), .allowed)
        XCTAssertEqual(s.verdict(.subject(s.verbs.id), .subjectsHeading), .allowed)
        XCTAssertFalse(s.verdict(.subject(s.grammar.id), .decksHeading).isAllowed, "a subject doesn't become a deck")
    }

    func testEveryDropIsEitherAllowedOrComesWithAReason() {
        let s = shelf
        var targets: [DropTarget] = [.subjectsHeading, .decksHeading]
        targets += s.subjects.map { .subject($0.id) }
        let items: [LibraryItem] = s.subjects.map { .subject($0.id) } + s.decks.map { .deck($0.id) }
        for item in items {
            for target in targets {
                switch s.verdict(item, target) {
                case .allowed: break
                case .refused(let reason): XCTAssertFalse(reason.isEmpty, "\(item) on \(target)")
                }
            }
        }
    }
}

final class MoveToMenuRulesTests: XCTestCase {
    private let shelf = Shelf()

    private func titles(_ nodes: [LibraryMove.Destination]) -> [String] {
        nodes.flatMap { [$0.title] + titles($0.children) }
    }

    func testADeckCanGoAnywhereButWhereItIs() {
        let s = shelf
        let d = LibraryMove.destinations(for: .deck(s.regular.id), subjects: s.subjects, decks: s.decks)
        XCTAssertEqual(d.unfile?.title, "No subject")
        XCTAssertEqual(titles(d.subjects), ["Spanish", "Grammar", "Biology", "Cells"], "not Verbs, which it is in")
    }

    func testALooseDeckHasNoNoSubjectChoice() {
        let s = shelf
        let d = LibraryMove.destinations(for: .deck(s.loose.id), subjects: s.subjects, decks: s.decks)
        XCTAssertNil(d.unfile)
        XCTAssertEqual(titles(d.subjects), ["Spanish", "Grammar", "Verbs", "Biology", "Cells"])
    }

    func testASubjectSeesOnlyWhereItFits() {
        let s = shelf
        // Grammar holds Verbs: two levels. It may go to the top level or under Biology, and nowhere else.
        let d = LibraryMove.destinations(for: .subject(s.grammar.id), subjects: s.subjects, decks: s.decks)
        XCTAssertEqual(d.unfile?.title, "Top level")
        XCTAssertEqual(titles(d.subjects), ["Biology"], "not itself, what it holds, its parent, or Cells (a fourth level)")
        XCTAssertEqual(d.subjects.first?.children, [], "Cells would be too deep, so it is hidden, not greyed")
    }

    func testATopLevelSubjectHasNoTopLevelChoice() {
        let s = shelf
        let d = LibraryMove.destinations(for: .subject(s.biology.id), subjects: s.subjects, decks: s.decks)
        XCTAssertNil(d.unfile)
        // Biology holds Cells (two levels): under Spanish (depth 1) it fits, under Grammar (depth 2) it doesn't.
        XCTAssertEqual(titles(d.subjects), ["Spanish"])
    }

    func testEverythingListedIsALegalMoveAndNothingLegalIsMissing() {
        let s = shelf
        let items: [LibraryItem] = s.subjects.map { .subject($0.id) } + s.decks.map { .deck($0.id) }
        func targets(_ nodes: [LibraryMove.Destination]) -> [Subject.ID] {
            nodes.flatMap { ($0.isTarget ? [$0.subjectID!] : []) + targets($0.children) }
        }
        for item in items {
            let d = LibraryMove.destinations(for: item, subjects: s.subjects, decks: s.decks)
            let listed = Set(targets(d.subjects))
            for subject in s.subjects {
                let allowed = s.verdict(item, .subject(subject.id)).isAllowed
                XCTAssertEqual(listed.contains(subject.id), allowed, "\(item) into \(subject.name)")
            }
        }
    }
}

final class SubjectDeletionPlanTests: XCTestCase {
    private let shelf = Shelf()

    func testTheConfirmationSaysWhatIsInside() {
        let s = shelf
        let plan = LibraryMove.DeletionPlan(subject: s.grammar, subjects: s.subjects, decks: s.decks)
        XCTAssertEqual(plan.title, "Delete “Grammar”?")
        XCTAssertEqual(plan.subjectCount, 1)
        XCTAssertEqual(plan.deckCount, 2)
        XCTAssertEqual(plan.cardCount, 52)
        XCTAssertEqual(plan.message, "It holds 1 subject, 2 decks and 52 cards.")
        XCTAssertEqual(LibraryMove.DeletionPlan.moveUpTitle, "Move its contents up")
        XCTAssertEqual(plan.deleteAllTitle, "Delete subject and its 1 subject, 2 decks and 52 cards")
    }

    func testASubjectWithOnlyDecksUsesTheTicketsWording() {
        let s = shelf
        let plan = LibraryMove.DeletionPlan(subject: s.verbs, subjects: s.subjects, decks: s.decks)
        XCTAssertEqual(plan.deleteAllTitle, "Delete subject and its 2 decks and 52 cards")
        XCTAssertEqual(plan.message, "It holds 2 decks and 52 cards.")
    }

    func testSingularsAndAnEmptySubject() {
        let lone = Subject(name: "Lone")
        let deck = Deck(name: "One", cards: [Card(front: "a", back: "b")], subjectID: lone.id)
        let plan = LibraryMove.DeletionPlan(subject: lone, subjects: [lone], decks: [deck])
        XCTAssertEqual(plan.message, "It holds 1 deck and 1 card.")
        XCTAssertEqual(plan.deleteAllTitle, "Delete subject and its 1 deck and 1 card")

        let empty = LibraryMove.DeletionPlan(subject: lone, subjects: [lone], decks: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.message, "This subject is empty.")
    }

    func testDeletingTheOpenSubjectSelectsItsParentOrTheFirstRow() {
        let s = shelf
        func after(_ subject: Subject, contents: Bool, current: LibrarySelection?) -> LibraryMove.SelectionAfterDelete {
            LibraryMove.selectionAfterDeleting(subject, deletingContents: contents, current: current, subjects: s.subjects, decks: s.decks)
        }
        XCTAssertEqual(after(s.grammar, contents: false, current: .subject(s.grammar.id)), .select(.subject(s.spanish.id)))
        XCTAssertEqual(after(s.spanish, contents: false, current: .subject(s.spanish.id)), .firstRow)
        // Keeping the contents: a deck that was inside is still there.
        XCTAssertEqual(after(s.verbs, contents: false, current: .deck(s.regular.id)), .unchanged)
        // Taking them too: the open deck, or a subject inside, is gone with it.
        XCTAssertEqual(after(s.verbs, contents: true, current: .deck(s.regular.id)), .select(.subject(s.grammar.id)))
        XCTAssertEqual(after(s.grammar, contents: true, current: .subject(s.verbs.id)), .select(.subject(s.spanish.id)))
        XCTAssertEqual(after(s.grammar, contents: false, current: .subject(s.verbs.id)), .unchanged)
        // Something else was open.
        XCTAssertEqual(after(s.grammar, contents: true, current: .deck(s.loose.id)), .unchanged)
        XCTAssertEqual(after(s.grammar, contents: true, current: nil), .unchanged)
    }
}

@MainActor
final class MoveAndUndoStoreTests: XCTestCase {
    private var directory: URL!
    private var undo: UndoManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        undo = UndoManager()
        undo.groupsByEvent = false
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func makeStore(_ shelf: Shelf = Shelf(), undoable: Bool = true) throws -> DeckStore {
        try DeckStorage(directory: directory).save(Library(subjects: shelf.subjects, decks: shelf.decks))
        let store = DeckStore(storage: DeckStorage(directory: directory), debounce: .milliseconds(1), onSaved: {})
        if undoable { store.undoManager = undo }
        return store
    }

    /// One user action: a group the undo manager can undo as a whole.
    private func act(_ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    func testMovingASubjectKeepsItsDecksSubSubjectsColorsAndSchedule() throws {
        let s = Shelf()
        let store = try makeStore(s)
        store.setColor(.orange, forSubject: s.grammar.id)
        let card = s.regular.cards[0]
        let playback = PlaybackStorage(directory: directory)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        var state = PlaybackState()
        state.reviews[card.id.uuidString] = ReviewScheduler.graded(nil, .good, at: when)
        try playback.save([s.regular.id: state])

        act { XCTAssertTrue(store.moveSubject(s.grammar.id, into: s.biology.id)) }

        let grammar = try XCTUnwrap(store.subjects.first { $0.id == s.grammar.id })
        XCTAssertEqual(grammar.parentID, s.biology.id)
        XCTAssertEqual(grammar.color, .orange)
        XCTAssertEqual(store.subjects.first { $0.id == s.verbs.id }?.parentID, s.grammar.id, "its sub-subject came with it")
        XCTAssertEqual(store.decks.first { $0.id == s.regular.id }?.subjectID, s.verbs.id)
        XCTAssertEqual(store.decks.count, 5)
        XCTAssertEqual(playback.load(), [s.regular.id: state], "review state stays with the deck id")
    }

    func testMovingADeckAndUndoingIt() throws {
        let s = Shelf()
        let store = try makeStore(s)
        act { XCTAssertTrue(store.moveDeck(s.loose.id, to: s.grammar.id)) }
        XCTAssertEqual(store.decks.first { $0.id == s.loose.id }?.subjectID, s.grammar.id)
        XCTAssertEqual(undo.undoActionName, "Move Deck")

        undo.undo()
        XCTAssertNil(store.decks.first { $0.id == s.loose.id }?.subjectID)
        XCTAssertEqual(store.decks.map(\.id), s.decks.map(\.id), "same order")

        undo.redo()
        XCTAssertEqual(store.decks.first { $0.id == s.loose.id }?.subjectID, s.grammar.id)
    }

    func testUndoingASubjectMoveRestoresItsParentAndPlace() throws {
        let s = Shelf()
        let store = try makeStore(s)
        let before = store.subjects.map(\.id)
        act { XCTAssertTrue(store.moveSubject(s.grammar.id, into: s.biology.id)) }
        XCTAssertNotEqual(store.subjects.map(\.id), before)
        XCTAssertEqual(undo.undoActionName, "Move Subject")

        undo.undo()
        XCTAssertEqual(store.subjects.map(\.id), before, "back in its place in the order")
        XCTAssertEqual(store.subjects.first { $0.id == s.grammar.id }?.parentID, s.spanish.id)
        undo.redo()
        XCTAssertEqual(store.subjects.first { $0.id == s.grammar.id }?.parentID, s.biology.id)
    }

    func testDeletingASubjectKeepingItsContentsAndUndoing() throws {
        let s = Shelf()
        let store = try makeStore(s)
        act { XCTAssertNotNil(store.deleteSubject(s.grammar.id)) }
        XCTAssertNil(store.subjects.first { $0.id == s.grammar.id })
        XCTAssertEqual(store.subjects.first { $0.id == s.verbs.id }?.parentID, s.spanish.id, "moved up one level")
        XCTAssertEqual(store.decks.count, 5, "no deck lost")
        XCTAssertEqual(undo.undoActionName, "Delete Subject")

        undo.undo()
        XCTAssertEqual(store.subjects.map(\.id), s.subjects.map(\.id), "restored, in its place")
        XCTAssertEqual(store.subjects.first { $0.id == s.verbs.id }?.parentID, s.grammar.id)
        XCTAssertEqual(store.subjects.first { $0.id == s.grammar.id }?.parentID, s.spanish.id)
        undo.redo()
        XCTAssertNil(store.subjects.first { $0.id == s.grammar.id })
    }

    func testDeletingASubjectAndItsContentsRemovesExactlyThoseAndUndoBringsThemBack() throws {
        let s = Shelf()
        let store = try makeStore(s)
        let playback = PlaybackStorage(directory: directory)
        var state = PlaybackState()
        state.reviews[s.cellDeck.cards[0].id.uuidString] = ReviewScheduler.graded(nil, .good, at: Date(timeIntervalSince1970: 1_800_000_000))
        try playback.save([s.cellDeck.id: state])

        act { XCTAssertEqual(store.deleteSubjectAndContents(s.grammar.id)?.cardCount, 52) }
        XCTAssertEqual(store.subjects.map(\.name), ["Spanish", "Biology", "Cells"])
        XCTAssertEqual(store.decks.map(\.name), ["Everyday Spanish", "World Capitals", "Cell structure"])
        XCTAssertEqual(playback.load()[s.cellDeck.id], state, "other decks' review state untouched")

        undo.undo()
        XCTAssertEqual(store.subjects.map(\.id), s.subjects.map(\.id))
        XCTAssertEqual(store.decks.map(\.id), s.decks.map(\.id), "decks back in their places")
        XCTAssertEqual(store.decks.first { $0.id == s.regular.id }?.cards.count, 30, "with their cards")
        XCTAssertEqual(store.decks.first { $0.id == s.regular.id }?.subjectID, s.verbs.id)
        undo.redo()
        XCTAssertEqual(store.decks.count, 3)
    }

    func testDeletingADeckCanBeUndone() throws {
        let s = Shelf()
        let store = try makeStore(s)
        act { XCTAssertNotNil(store.deleteDeck(s.irregular.id)) }
        XCTAssertEqual(store.decks.count, 4)
        undo.undo()
        XCTAssertEqual(store.decks.map(\.id), s.decks.map(\.id))
        XCTAssertEqual(undo.redoActionName, "Delete Deck")
    }

    func testUndoKeepsEditsMadeSince() throws {
        let s = Shelf()
        let store = try makeStore(s)
        act { store.moveSubject(s.grammar.id, into: s.biology.id) }
        // Meanwhile: a rename, a card edit in a deck inside, and a new deck.
        store.renameSubject(s.grammar.id, to: "Grammar rules")
        store.addCard(to: s.regular.id, front: "new", back: "new")
        let added = store.addDeck(name: "Added later")

        undo.undo()
        let grammar = try XCTUnwrap(store.subjects.first { $0.id == s.grammar.id })
        XCTAssertEqual(grammar.parentID, s.spanish.id)
        XCTAssertEqual(grammar.name, "Grammar rules", "the rename stays")
        XCTAssertEqual(store.decks.first { $0.id == s.regular.id }?.cards.count, 31, "and the card")
        XCTAssertNotNil(store.decks.first { $0.id == added.id })
    }

    func testNamesMayRepeatInTheSamePlace() throws {
        let s = Shelf()
        let store = try makeStore(s)
        XCTAssertNotNil(store.addSubject(name: "Verbs", parentID: s.grammar.id), "same name, same parent")
        XCTAssertTrue(store.renameSubject(s.cells.id, to: "Biology"))
        let twin = store.addDeck(name: "Regular verbs")
        act { XCTAssertTrue(store.moveDeck(twin.id, to: s.verbs.id), "a deck with the same name as one already there") }
        XCTAssertEqual(store.decks.filter { $0.name == "Regular verbs" }.count, 2)
    }

    func testWithoutAnUndoManagerEverythingStillWorks() throws {
        let s = Shelf()
        let store = try makeStore(s, undoable: false)
        XCTAssertTrue(store.moveDeck(s.loose.id, to: s.spanish.id))
        XCTAssertNotNil(store.deleteSubject(s.grammar.id))
        XCTAssertFalse(undo.canUndo)
    }

    func testARefusedMoveRegistersNoUndo() throws {
        let s = Shelf()
        let store = try makeStore(s)
        act { XCTAssertFalse(store.moveSubject(s.spanish.id, into: s.verbs.id)) }
        XCTAssertEqual(undo.undoActionName, "", "nothing to undo")
        act { XCTAssertTrue(store.moveDeck(s.everyday.id, to: s.spanish.id), "already there: nothing to do") }
        XCTAssertEqual(undo.undoActionName, "")
    }
}

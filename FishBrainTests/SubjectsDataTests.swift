import XCTest

/// Subjects data (FLAS-62): the Subject model, `decks.json` version 3 and the rules that keep the tree sound.
final class SubjectTreeTests: XCTestCase {
    /// Spanish > Grammar > Verbs, and Biology (top level) > Cells.
    private let spanish = Subject(name: "Spanish")
    private lazy var grammar = Subject(name: "Grammar", parentID: spanish.id)
    private lazy var verbs = Subject(name: "Verbs", parentID: grammar.id)
    private let biology = Subject(name: "Biology")
    private lazy var cells = Subject(name: "Cells", parentID: biology.id)
    private lazy var tree = SubjectTree([spanish, grammar, verbs, biology, cells])

    func testDepthAncestorsAndDescendants() {
        XCTAssertEqual(tree.depth(of: spanish.id), 1)
        XCTAssertEqual(tree.depth(of: grammar.id), 2)
        XCTAssertEqual(tree.depth(of: verbs.id), 3)
        XCTAssertNil(tree.depth(of: UUID()))

        XCTAssertEqual(tree.ancestors(of: verbs.id).map(\.name), ["Grammar", "Spanish"], "nearest first")
        XCTAssertTrue(tree.ancestors(of: spanish.id).isEmpty)
        XCTAssertEqual(tree.descendants(of: spanish.id).map(\.name), ["Grammar", "Verbs"])
        XCTAssertEqual(tree.descendants(of: biology.id).map(\.name), ["Cells"])
        XCTAssertTrue(tree.descendants(of: verbs.id).isEmpty)
        XCTAssertEqual(tree.height(of: spanish.id), 3)
        XCTAssertEqual(tree.height(of: grammar.id), 2)
        XCTAssertEqual(tree.height(of: verbs.id), 1)
        XCTAssertEqual(tree.path(of: verbs.id), "Spanish › Grammar › Verbs")
    }

    func testTheCapIsThreeAndIsOneConstant() {
        XCTAssertEqual(Subject.maxDepth, 3)
        XCTAssertFalse(tree.canAdd(under: verbs.id), "a fourth level")
        XCTAssertTrue(tree.canAdd(under: grammar.id))
        XCTAssertTrue(tree.canAdd(under: nil))
    }

    func testASubjectCannotMoveIntoItselfOrWhatItHolds() {
        XCTAssertFalse(tree.canMove(spanish.id, into: spanish.id))
        XCTAssertFalse(tree.canMove(spanish.id, into: grammar.id), "its child")
        XCTAssertFalse(tree.canMove(spanish.id, into: verbs.id), "its grandchild")
        XCTAssertFalse(tree.canMove(UUID(), into: nil), "unknown")
        XCTAssertFalse(tree.canMove(grammar.id, into: UUID()), "unknown parent")
    }

    func testMovingCountsTheDepthOfWhatItAlreadyHolds() {
        // Grammar holds Verbs (two levels). Inside Biology (depth 1) that would be 1 + 2 = 3: allowed.
        XCTAssertTrue(tree.canMove(grammar.id, into: biology.id))
        // Inside Cells (depth 2) it would reach depth 4.
        XCTAssertFalse(tree.canMove(grammar.id, into: cells.id))
        // Spanish holds two levels below it (three in all), so it can only be at the top.
        XCTAssertFalse(tree.canMove(spanish.id, into: biology.id))
        XCTAssertTrue(tree.canMove(spanish.id, into: nil))
        // A leaf can go anywhere there is room.
        XCTAssertTrue(tree.canMove(verbs.id, into: cells.id))
        XCTAssertTrue(tree.canMove(verbs.id, into: nil))
        XCTAssertTrue(tree.canMove(cells.id, into: grammar.id))
        XCTAssertFalse(tree.canMove(cells.id, into: verbs.id), "a fourth level")
    }

    func testDecksInASubjectIncludeItsSubSubjectsInDeckOrder() {
        let a = Deck(name: "a", subjectID: spanish.id)
        let b = Deck(name: "b", subjectID: verbs.id)
        let c = Deck(name: "c", subjectID: biology.id)
        let loose = Deck(name: "loose")
        let d = Deck(name: "d", subjectID: grammar.id)
        let decks = [a, b, c, loose, d]
        XCTAssertEqual(tree.decks(in: spanish.id, among: decks).map(\.name), ["a", "b", "d"])
        XCTAssertEqual(tree.decks(in: spanish.id, among: decks, includingSubSubjects: false).map(\.name), ["a"])
        XCTAssertEqual(tree.decks(in: grammar.id, among: decks).map(\.name), ["b", "d"])
        XCTAssertEqual(tree.decks(in: biology.id, among: decks).map(\.name), ["c"])
        XCTAssertTrue(tree.decks(in: UUID(), among: decks).isEmpty)
    }

    func testHelpersDontLoopOnACorruptTree() {
        var a = Subject(name: "a"), b = Subject(name: "b")
        a.parentID = b.id
        b.parentID = a.id
        let broken = SubjectTree([a, b])
        XCTAssertNil(broken.depth(of: a.id))
        XCTAssertEqual(broken.ancestors(of: a.id).map(\.name), ["b"])
        XCTAssertEqual(Set(broken.descendants(of: a.id).map(\.name)), ["b"])
        XCTAssertFalse(broken.canMove(a.id, into: nil) && broken.height(of: a.id) > Subject.maxDepth)
    }

    func testNamesAreTrimmedAndNotBlankAndMayRepeatInDifferentParents() {
        XCTAssertEqual(Subject.cleanName("  Spanish \n"), "Spanish")
        XCTAssertNil(Subject.cleanName("   \n"))
        XCTAssertNil(Subject.cleanName(""))
        // "Verbs" in two parents is fine.
        let french = Subject(name: "French")
        let frenchVerbs = Subject(name: "Verbs", parentID: french.id)
        XCTAssertEqual(SubjectTree([spanish, grammar, verbs, french, frenchVerbs]).subjects.filter { $0.name == "Verbs" }.count, 2)
    }
}

final class LibraryRepairTests: XCTestCase {
    func testASoundLibraryIsUntouched() {
        let s = Subject(name: "Spanish")
        let library = Library(subjects: [s, Subject(name: "Grammar", parentID: s.id)], decks: [Deck(name: "a", subjectID: s.id), Deck(name: "b")])
        let result = library.repaired()
        XCTAssertEqual(result.library, library)
        XCTAssertTrue(result.repairs.isEmpty)
    }

    func testAMissingParentGoesToTheTopLevel() {
        let orphan = Subject(name: "Orphan", parentID: UUID())
        let result = Library(subjects: [orphan]).repaired()
        XCTAssertNil(result.library.subjects[0].parentID)
        XCTAssertEqual(result.repairs.count, 1)
    }

    func testACycleIsCutAndNothingIsDropped() {
        var a = Subject(name: "a"), b = Subject(name: "b"), c = Subject(name: "c")
        a.parentID = c.id
        b.parentID = a.id
        c.parentID = b.id
        let deck = Deck(name: "kept", cards: [Card(front: "f", back: "b")], subjectID: b.id)
        let result = Library(subjects: [a, b, c], decks: [deck]).repaired()
        XCTAssertEqual(result.library.subjects.count, 3, "no subject dropped")
        XCTAssertEqual(result.library.decks, [deck], "and no deck or card")
        let tree = SubjectTree(result.library.subjects)
        for subject in result.library.subjects { XCTAssertNotNil(tree.depth(of: subject.id), "\(subject.name) is in a tree again") }
        XCTAssertFalse(result.repairs.isEmpty)
    }

    func testASubjectTooDeepGoesToTheTopLevel() {
        let one = Subject(name: "1")
        let two = Subject(name: "2", parentID: one.id)
        let three = Subject(name: "3", parentID: two.id)
        let four = Subject(name: "4", parentID: three.id)
        let five = Subject(name: "5", parentID: four.id)
        let result = Library(subjects: [one, two, three, four, five]).repaired()
        let tree = SubjectTree(result.library.subjects)
        for subject in result.library.subjects {
            XCTAssertLessThanOrEqual(tree.depth(of: subject.id) ?? 99, Subject.maxDepth, subject.name)
        }
        XCTAssertNil(result.library.subjects.first { $0.name == "4" }?.parentID, "the first one past the cap")
        XCTAssertEqual(result.library.subjects.first { $0.name == "5" }?.parentID, four.id, "and what was in it keeps its parent")
        XCTAssertEqual(result.library.subjects.count, 5)
    }

    func testDecksOfAMissingSubjectBecomeLoose() {
        let deck = Deck(name: "lost", cards: [Card(front: "a", back: "b")], subjectID: UUID())
        let result = Library(decks: [deck]).repaired()
        XCTAssertNil(result.library.decks[0].subjectID)
        XCTAssertEqual(result.library.decks[0].cards, deck.cards)
    }

    func testADuplicatedSubjectKeepsItsFirstAppearance() {
        let s = Subject(name: "Spanish")
        var again = s
        again.name = "Spanish copy"
        let result = Library(subjects: [s, again]).repaired()
        XCTAssertEqual(result.library.subjects.map(\.name), ["Spanish"])
    }
}

final class LibraryFileVersionTests: XCTestCase {
    private var directory: URL!
    private var storage: DeckStorage!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storage = DeckStorage(directory: directory)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testVersionThreeRoundTrip() throws {
        let spanish = Subject(name: "Spanish", color: .orange)
        let grammar = Subject(name: "Grammar", color: .green, parentID: spanish.id)
        let library = Library(
            subjects: [spanish, grammar],
            decks: [
                Deck(name: "Verbs", color: .purple, cards: [Card(front: "hablar", back: "to speak")], subjectID: grammar.id),
                Deck(name: "Loose"),
            ]
        )
        try storage.save(library)
        XCTAssertEqual(storage.loadLibrary(), library)
        XCTAssertEqual(storage.load(), library.decks, "load() still gives the decks flat")

        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storage.fileURL)) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 3)
        XCTAssertEqual((envelope["subjects"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((envelope["decks"] as? [[String: Any]])?.count, 2)
    }

    func testVersionOneAndTwoFilesLoadUnchangedWithNoSubjects() throws {
        let id = UUID(), card = UUID()
        let deck = #"{"id":"\#(id)","name":"Old","color":"green","cards":[{"id":"\#(card)","front":"a","back":"b"}]}"#
        for version in [1, 2] {
            try Data(#"{"version":\#(version),"decks":[\#(deck)]}"#.utf8).write(to: storage.fileURL)
            let library = storage.loadLibrary()
            XCTAssertEqual(library.decks.map(\.name), ["Old"], "version \(version)")
            XCTAssertEqual(library.decks.first?.cards.first?.front, "a")
            XCTAssertTrue(library.subjects.isEmpty)
            XCTAssertNil(library.decks.first?.subjectID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: storage.fileURL.path), "not moved aside")
        }
    }

    func testAFutureVersionIsRefusedAndKeptAside() throws {
        try Data(#"{"version":4,"subjects":[],"decks":[]}"#.utf8).write(to: storage.fileURL)
        XCTAssertEqual(storage.loadLibrary(), Library())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.contains(DeckStorage.fileName), "not left to be saved back without its subjects")
        XCTAssertEqual(files.filter { $0.hasPrefix("decks.corrupt-") }.count, 1)
    }

    func testAVersionThreeFileFromTheDesignLoads() throws {
        let s = UUID(), g = UUID(), d = UUID()
        let json = """
        { "version": 3,
          "subjects": [
            { "id": "\(s)", "name": "Spanish", "color": "accent" },
            { "id": "\(g)", "name": "Grammar", "color": "accent", "parentID": "\(s)" } ],
          "decks": [ { "id": "\(d)", "name": "Verbs", "color": "accent", "subjectID": "\(g)", "cards": [] } ] }
        """
        try Data(json.utf8).write(to: storage.fileURL)
        let library = storage.loadLibrary()
        XCTAssertEqual(library.subjects.map(\.name), ["Spanish", "Grammar"])
        XCTAssertEqual(library.subjects[1].parentID, s)
        XCTAssertNil(library.subjects[0].parentID)
        XCTAssertEqual(library.decks[0].subjectID, g)
    }

    func testACorruptFileIsRepairedAsItIsRead() throws {
        let a = UUID(), b = UUID(), d = UUID()
        let json = """
        { "version": 3,
          "subjects": [
            { "id": "\(a)", "name": "a", "color": "accent", "parentID": "\(b)" },
            { "id": "\(b)", "name": "b", "color": "accent", "parentID": "\(a)" } ],
          "decks": [ { "id": "\(d)", "name": "Kept", "color": "accent", "subjectID": "\(UUID())",
                       "cards": [ { "id": "\(UUID())", "front": "f", "back": "b" } ] } ] }
        """
        try Data(json.utf8).write(to: storage.fileURL)
        let library = storage.loadLibrary()
        XCTAssertEqual(library.subjects.count, 2)
        XCTAssertNotNil(SubjectTree(library.subjects).depth(of: a))
        XCTAssertNotNil(SubjectTree(library.subjects).depth(of: b))
        XCTAssertEqual(library.decks.first?.name, "Kept")
        XCTAssertEqual(library.decks.first?.cards.count, 1, "no card dropped")
        XCTAssertNil(library.decks.first?.subjectID, "its subject didn't exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.fileURL.path), "repaired, not moved aside")
    }

    func testAFiveThousandCardLibraryLoadsAsFastAsBefore() throws {
        let spanish = Subject(name: "Spanish")
        let decks = (0..<50).map { d in
            Deck(name: "Deck \(d)", cards: (0..<100).map { Card(front: "front \(d) \($0)", back: "back \(d) \($0)") }, subjectID: d.isMultiple(of: 2) ? spanish.id : nil)
        }
        XCTAssertEqual(decks.reduce(0) { $0 + $1.cards.count }, 5_000)
        try storage.save(Library(subjects: [spanish], decks: decks))
        // The same library as a version 2 file, for comparison.
        let legacyDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacy = DeckStorage(directory: legacyDirectory)
        var plain = decks
        for i in plain.indices { plain[i].subjectID = nil }
        let encoder = JSONEncoder()
        struct V2: Codable { var version: Int; var decks: [Deck] }
        try encoder.encode(V2(version: 2, decks: plain)).write(to: legacy.fileURL)

        func time(_ storage: DeckStorage) -> TimeInterval {
            var best = TimeInterval.infinity
            for _ in 0..<3 {
                let start = Date()
                XCTAssertEqual(storage.loadLibrary().decks.count, 50)
                best = min(best, Date().timeIntervalSince(start))
            }
            return best
        }
        let v2 = time(legacy), v3 = time(storage)
        XCTAssertLessThan(v3, max(v2 * 3, 0.25), "version 3 \(v3) s, version 2 \(v2) s")
    }
}

@MainActor
final class SubjectsInTheStoreTests: XCTestCase {
    private var directory: URL!
    private var saved = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        saved = 0
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func makeStore() -> DeckStore {
        DeckStore(storage: DeckStorage(directory: directory), debounce: .milliseconds(1), onSaved: { [unowned self] in saved += 1 })
    }

    func testAddRenameColorAndSave() async throws {
        let store = makeStore()
        let spanish = try XCTUnwrap(store.addSubject(name: "  Spanish "))
        XCTAssertEqual(spanish.name, "Spanish")
        let grammar = try XCTUnwrap(store.addSubject(name: "Grammar", color: .green, parentID: spanish.id))
        XCTAssertEqual(store.subjects.map(\.name), ["Spanish", "Grammar"])

        XCTAssertTrue(store.renameSubject(grammar.id, to: " Grammar rules "))
        XCTAssertFalse(store.renameSubject(grammar.id, to: "   "))
        XCTAssertFalse(store.renameSubject(UUID(), to: "x"))
        store.setColor(.purple, forSubject: spanish.id)

        await store.settled()
        XCTAssertGreaterThan(saved, 0, "saves and widget reloads work as for decks")
        let reopened = makeStore()
        XCTAssertEqual(reopened.subjects.map(\.name), ["Spanish", "Grammar rules"])
        XCTAssertEqual(reopened.subjects[0].color, .purple)
        XCTAssertEqual(reopened.subjects[1].parentID, spanish.id)
    }

    func testNewSubjectsGetUniqueDefaultNamesAmongSiblings() {
        let store = makeStore()
        XCTAssertEqual(store.addSubject()?.name, "New Subject")
        XCTAssertEqual(store.addSubject()?.name, "New Subject 2")
        let parent = store.subjects[0]
        XCTAssertEqual(store.addSubject(parentID: parent.id)?.name, "New Subject", "a different parent")
    }

    func testBlankNamesUnknownParentsAndTheCapAreRefused() {
        let store = makeStore()
        XCTAssertNil(store.addSubject(name: "   "))
        XCTAssertNil(store.addSubject(name: "x", parentID: UUID()))
        let one = store.addSubject(name: "1")!
        let two = store.addSubject(name: "2", parentID: one.id)!
        let three = store.addSubject(name: "3", parentID: two.id)!
        XCTAssertNil(store.addSubject(name: "4", parentID: three.id), "a fourth level")
        XCTAssertEqual(store.subjects.count, 3)
    }

    func testMovingSubjectsHonoursTheRules() {
        let store = makeStore()
        let spanish = store.addSubject(name: "Spanish")!
        let grammar = store.addSubject(name: "Grammar", parentID: spanish.id)!
        let verbs = store.addSubject(name: "Verbs", parentID: grammar.id)!
        let biology = store.addSubject(name: "Biology")!

        XCTAssertFalse(store.moveSubject(spanish.id, into: verbs.id), "into what it holds")
        XCTAssertFalse(store.moveSubject(spanish.id, into: biology.id), "it already holds two levels")
        XCTAssertTrue(store.moveSubject(grammar.id, into: biology.id), "Grammar and Verbs fit under Biology")
        XCTAssertEqual(store.subjects.first { $0.id == grammar.id }?.parentID, biology.id)
        XCTAssertEqual(store.subjects.first { $0.id == verbs.id }?.parentID, grammar.id, "what it holds goes with it")
        XCTAssertTrue(store.moveSubject(grammar.id, into: nil))
        XCTAssertNil(store.subjects.first { $0.id == grammar.id }?.parentID)
        XCTAssertEqual(store.subjects.count, 4, "nothing lost")
    }

    func testFilingADeckKeepsItsIDCardsAndPlace() {
        let store = makeStore()
        let subject = store.addSubject(name: "Spanish")!
        let a = store.addDeck(name: "a"), b = store.addDeck(name: "b"), c = store.addDeck(name: "c")
        XCTAssertTrue(store.moveDeck(b.id, to: subject.id))
        XCTAssertEqual(store.decks.map(\.id), [a.id, b.id, c.id], "deck order is the array order, unchanged")
        XCTAssertEqual(store.decks[1].subjectID, subject.id)
        XCTAssertEqual(store.decks[1].id, b.id, "so its schedule stays with it")
        XCTAssertTrue(store.moveDeck(b.id, to: nil), "a loose deck again")
        XCTAssertNil(store.decks[1].subjectID)
        XCTAssertFalse(store.moveDeck(b.id, to: UUID()))
        XCTAssertFalse(store.moveDeck(UUID(), to: subject.id))
    }

    func testDeletingASubjectMovesWhatIsInsideItUpOneLevel() {
        let store = makeStore()
        let spanish = store.addSubject(name: "Spanish")!
        let grammar = store.addSubject(name: "Grammar", parentID: spanish.id)!
        let verbs = store.addSubject(name: "Verbs", parentID: grammar.id)!
        let deck = store.addDeck(name: "Irregular")
        store.moveDeck(deck.id, to: grammar.id)
        let card = store.addCard(to: deck.id, front: "ir", back: "to go")!

        XCTAssertEqual(store.deleteSubject(grammar.id)?.name, "Grammar")
        XCTAssertEqual(store.subjects.map(\.name), ["Spanish", "Verbs"])
        XCTAssertEqual(store.subjects.first { $0.id == verbs.id }?.parentID, spanish.id, "up one level")
        XCTAssertEqual(store.decks.first { $0.id == deck.id }?.subjectID, spanish.id)
        XCTAssertEqual(store.card(card.id, in: deck.id)?.front, "ir")

        // A top-level subject: its decks and sub-subjects go to the top level.
        XCTAssertNotNil(store.deleteSubject(spanish.id))
        XCTAssertNil(store.subjects.first?.parentID)
        XCTAssertNil(store.decks.first { $0.id == deck.id }?.subjectID)
        XCTAssertNil(store.deleteSubject(UUID()))
    }

    func testDeleteKeepsReviewStateBecauseTheDeckIDIsTheSame() throws {
        let playbackStorage = PlaybackStorage(directory: directory)
        let store = makeStore()
        let subject = store.addSubject(name: "Spanish")!
        let deck = store.addDeck(name: "Verbs")
        let card = store.addCard(to: deck.id, front: "a", back: "b")!
        store.moveDeck(deck.id, to: subject.id)
        let loaded = try XCTUnwrap(store.decks.first)
        // The deck has one card, so it is the one on show: turn it over and grade it.
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        try PlaybackActions.flip(loaded, in: playbackStorage, at: when)
        try PlaybackActions.grade(.good, loaded, in: playbackStorage, at: when)
        let before = playbackStorage.load()

        store.deleteSubject(subject.id)

        XCTAssertEqual(store.decks.first?.id, deck.id)
        XCTAssertEqual(playbackStorage.load(), before, "the schedule is exactly as it was")
        XCTAssertNotNil(playbackStorage.load()[deck.id]?.review(for: card.id))
    }

    func testDeletingASubjectAndItsContentsIsTheSeparateChoice() {
        let store = makeStore()
        let spanish = store.addSubject(name: "Spanish")!
        let grammar = store.addSubject(name: "Grammar", parentID: spanish.id)!
        let biology = store.addSubject(name: "Biology")!
        let a = store.addDeck(name: "a"), b = store.addDeck(name: "b"), c = store.addDeck(name: "c")
        store.addCard(to: a.id, front: "1", back: "1")
        store.addCard(to: b.id, front: "2", back: "2")
        store.addCard(to: b.id, front: "3", back: "3")
        store.moveDeck(a.id, to: spanish.id)
        store.moveDeck(b.id, to: grammar.id)
        store.moveDeck(c.id, to: biology.id)

        let removed = store.deleteSubjectAndContents(spanish.id)
        XCTAssertEqual(removed?.subjects.map(\.name), ["Spanish", "Grammar"])
        XCTAssertEqual(removed?.decks.map(\.name), ["a", "b"])
        XCTAssertEqual(removed?.cardCount, 3)
        XCTAssertEqual(store.subjects.map(\.name), ["Biology"])
        XCTAssertEqual(store.decks.map(\.name), ["c"], "the other subject's deck is untouched")
        XCTAssertNil(store.deleteSubjectAndContents(UUID()))
    }

    func testReorderingSubjectsIsTheArrayOrder() {
        let store = makeStore()
        store.addSubject(name: "a"); store.addSubject(name: "b"); store.addSubject(name: "c")
        store.reorderSubjects(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.subjects.map(\.name), ["c", "a", "b"])
    }

    func testTheWidgetsDeckReadStaysFlat() async throws {
        let store = makeStore()
        let subject = store.addSubject(name: "Spanish")!
        let deck = store.addDeck(name: "Verbs")
        store.moveDeck(deck.id, to: subject.id)
        await store.settled()
        // What the widget and the notch read: decks, flat, with no need to know about subjects.
        XCTAssertEqual(DeckStorage(directory: directory).load().map(\.name), ["Verbs"])
    }
}

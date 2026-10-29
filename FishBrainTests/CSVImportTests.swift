import XCTest

final class CSVTableTests: XCTestCase {
    private func table(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> CSVTable {
        try CSVTable.read(Data(text.utf8)).get()
    }

    func testReadsRowsColumnsAndTheSeparator() throws {
        let t = try table("Front;Back;Deck\nhola;hello;Spanish\nla mesa;the table;Spanish")
        XCTAssertEqual(t.delimiter, .semicolon)
        XCTAssertEqual(t.rows.count, 3)
        XCTAssertEqual(t.columnCount, 3)
        XCTAssertEqual(t.rows[1].fields, ["hola", "hello", "Spanish"])
        XCTAssertEqual(t.rows.map(\.number), [1, 2, 3])
    }

    func testRowNumbersCountEveryRecordIncludingBrokenOnes() throws {
        let t = try table("a,b\n\"never closed,x\nc,d")
        XCTAssertEqual(t.rows.map(\.number), [1, 3])
        XCTAssertEqual(t.brokenRecords, [2])
    }

    func testAMultiLineFieldIsOneRow() throws {
        let t = try table("\"one\ntwo\",back\nnext,card")
        XCTAssertEqual(t.rows.count, 2)
        XCTAssertEqual(t.rows[0].fields[0], "one\ntwo")
    }

    func testHeaderDetection() throws {
        XCTAssertTrue(try table("Front,Back\na,b").looksLikeHeader)
        XCTAssertTrue(try table("front,back,deck,subject\na,b,c,d").looksLikeHeader)
        XCTAssertTrue(try table("Deck,Front\na,b").looksLikeHeader)
        XCTAssertFalse(try table("hola,hello\nla mesa,the table").looksLikeHeader)
        XCTAssertFalse(try table("Front,something,else\na,b,c").looksLikeHeader, "one name among three columns isn't enough")
    }

    func testColumnTitlesUseTheHeaderOrNumbers() throws {
        let t = try table("Front,,Deck\na,b,c")
        XCTAssertEqual(t.columnTitles(hasHeader: true), ["Front", "Column 2", "Deck"])
        XCTAssertEqual(t.columnTitles(hasHeader: false), ["Column 1", "Column 2", "Column 3"])
    }

    func testFailures() {
        XCTAssertEqual(CSVTable.read(Data()), .failure(.emptyFile))
        XCTAssertEqual(CSVTable.read(Data("  \n \n".utf8)), .failure(.emptyFile))
        XCTAssertEqual(CSVTable.read(Data([0x00, 0x01, 0x02, 0x00])), .failure(.notTextFile))
        XCTAssertEqual(CSVTable.read(Data(repeating: 65, count: 100), maxBytes: 10), .failure(.tooLarge(bytes: 100, limit: 10)))
        XCTAssertEqual(CSVTable.read(Data("\"never closed".utf8)), .failure(.noCards(skippedLines: 1)))
    }

    func testEncodingIsReported() throws {
        let latin1 = Data(Array("caf".utf8) + [0xE9] + Array(",coffee".utf8))
        XCTAssertEqual(try CSVTable.read(latin1).get().encoding, .windowsLatin1)
        XCTAssertEqual(try table("a,b").encoding, .utf8)
    }
}

final class CSVColumnMappingTests: XCTestCase {
    func testMatchesNamesCaseInsensitively() {
        let m = CSVColumnMapping.detect(header: ["Subject", "DECK", "back", "Front"], columnCount: 4)
        XCTAssertEqual(m, CSVColumnMapping(front: [3], back: [2], deck: 1, subject: 0))
        XCTAssertTrue(m.isUsable)
    }

    func testAcceptsCommonSynonyms() {
        let m = CSVColumnMapping.detect(header: ["Term", "Definition"], columnCount: 2)
        XCTAssertEqual(m, CSVColumnMapping(front: [0], back: [1], deck: nil, subject: nil))
        XCTAssertEqual(CSVColumnMapping.detect(header: ["Question", "Answer"], columnCount: 2).front, [0])
    }

    func testWithoutAHeaderTheFirstTwoColumnsAreFrontAndBack() {
        let m = CSVColumnMapping.detect(header: nil, columnCount: 4)
        XCTAssertEqual(m, CSVColumnMapping(front: [0], back: [1], deck: nil, subject: nil))
    }

    func testAHeaderWithoutNamesFallsBackToFreeColumns() {
        // Deck is named; front and back are the first two columns that aren't taken.
        let m = CSVColumnMapping.detect(header: ["Deck", "Spanish word", "English word"], columnCount: 3)
        XCTAssertEqual(m, CSVColumnMapping(front: [1], back: [2], deck: 0, subject: nil))
    }

    func testOneColumnIsNotUsable() {
        let m = CSVColumnMapping.detect(header: nil, columnCount: 1)
        XCTAssertEqual(m.front, [0])
        XCTAssertEqual(m.back, [])
        XCTAssertFalse(m.isUsable)
        XCTAssertFalse(CSVColumnMapping(front: [0], back: [0]).isUsable)
    }

    // MARK: Several columns on a side (FLAS-97, FLAS-98)

    func testExtraColumnsJoinTheBackAfterItsMainColumn() {
        let m = CSVColumnMapping.detect(header: ["Word", "Meaning", "Example"], columnCount: 3)
        XCTAssertEqual(m.front, [0])
        XCTAssertEqual(m.back, [1, 2])
    }

    func testExtrasKeepFileOrderAfterTheMainBack() {
        let m = CSVColumnMapping.detect(header: ["Notes", "Term", "IPA", "Definition", "Sentence"], columnCount: 5)
        XCTAssertEqual(m.front, [1])
        XCTAssertEqual(m.back, [3, 0, 2, 4])
    }

    func testUnknownNamesUseTheFirstTwoColumns() {
        let m = CSVColumnMapping.detect(header: ["Spanish", "English", "Level"], columnCount: 3)
        XCTAssertEqual(m, CSVColumnMapping(front: [0], back: [1]))
    }

    func testIsUsableRejectsAColumnOnBothSides() {
        XCTAssertFalse(CSVColumnMapping(front: [0], back: [1, 0]).isUsable)
        XCTAssertFalse(CSVColumnMapping(front: [], back: [1]).isUsable)
        XCTAssertFalse(CSVColumnMapping(front: [0], back: []).isUsable)
        XCTAssertTrue(CSVColumnMapping(front: [0, 2], back: [1]).isUsable)
    }

    func testAHeaderOfWordMeaningExampleLooksLikeOne() throws {
        let t = try CSVTable.read(Data("Word,Meaning,Example\nhablar,to speak,Hablo español.".utf8)).get()
        XCTAssertTrue(t.looksLikeHeader)
    }
}

final class CSVImportPlanTests: XCTestCase {
    private func table(_ text: String) throws -> CSVTable { try CSVTable.read(Data(text.utf8)).get() }

    private func plan(
        _ text: String, destination: CSVImportDestination = .fromFile, skipDuplicates: Bool = false,
        library: Library = Library(), context: Subject.ID? = nil, file: String = "My file"
    ) throws -> CSVImportPlan {
        let t = try table(text)
        let hasHeader = t.looksLikeHeader
        let options = CSVImportOptions(
            hasHeader: hasHeader,
            mapping: CSVColumnMapping.detect(header: hasHeader ? t.rows.first?.fields : nil, columnCount: t.columnCount),
            destination: destination, skipDuplicates: skipDuplicates
        )
        return CSVImport.plan(table: t, options: options, library: library, contextSubjectID: context, fileName: file)
    }

    private let sample = """
    Front,Back,Deck,Subject
    hablar,to speak,Regular,Spanish › Grammar › Verbs
    comer,to eat,Regular,Spanish › Grammar › Verbs
    pretérito,preterite,Tenses,Spanish › Grammar
    hola,hello,Phrases,Spanish
    a,b,Loose,
    """

    // MARK: Subject paths

    func testSubjectNamesAcceptEachSeparator() {
        XCTAssertEqual(CSVImport.subjectNames("Spanish › Grammar"), ["Spanish", "Grammar"])
        XCTAssertEqual(CSVImport.subjectNames("Spanish::Grammar::Verbs"), ["Spanish", "Grammar", "Verbs"])
        XCTAssertEqual(CSVImport.subjectNames("Spanish / Grammar"), ["Spanish", "Grammar"])
        XCTAssertEqual(CSVImport.subjectNames(" Spanish ›  › Grammar "), ["Spanish", "Grammar"], "blank names are dropped")
        XCTAssertEqual(CSVImport.subjectNames(""), [])
    }

    // MARK: Structure from the file

    func testBuildsSubjectsAndDecksFromTheColumns() throws {
        let p = try plan(sample)
        XCTAssertEqual(p.newSubjects.map(\.name), ["Spanish", "Grammar", "Verbs"])
        XCTAssertEqual(p.newDecks.map(\.name), ["Regular", "Tenses", "Phrases", "Loose"])
        XCTAssertEqual(p.cardCount, 5)
        XCTAssertEqual(p.deckCount, 4)
        XCTAssertEqual(p.subjectCount, 3)

        let spanish = p.newSubjects[0], grammar = p.newSubjects[1], verbs = p.newSubjects[2]
        XCTAssertNil(spanish.parentID)
        XCTAssertEqual(grammar.parentID, spanish.id)
        XCTAssertEqual(verbs.parentID, grammar.id)
        XCTAssertEqual(p.newDecks[0].subjectID, verbs.id)
        XCTAssertEqual(p.newDecks[0].cards.map(\.front), ["hablar", "comer"], "rows with the same deck share one")
        XCTAssertEqual(p.newDecks[1].subjectID, grammar.id)
        XCTAssertEqual(p.newDecks[2].subjectID, spanish.id)
        XCTAssertNil(p.newDecks[3].subjectID, "no subject: a loose deck")
        XCTAssertTrue(p.skipped.isEmpty)
    }

    func testTheSameDeckNameUnderDifferentSubjectsIsTwoDecks() throws {
        let p = try plan("Front,Back,Deck,Subject\na,b,Verbs,Spanish\nc,d,Verbs,French")
        XCTAssertEqual(p.newDecks.count, 2)
        XCTAssertEqual(Set(p.newSubjects.map(\.name)), ["Spanish", "French"])
    }

    func testNamesThatExistAreNeverMergedInto() throws {
        let existing = Subject(name: "Spanish")
        let deck = Deck(name: "Regular", cards: [Card(front: "x", back: "y")], subjectID: existing.id)
        let p = try plan(sample, library: Library(subjects: [existing], decks: [deck]))
        XCTAssertEqual(p.newSubjects.filter { $0.name == "Spanish" }.count, 1, "a new Spanish is made next to the old one")
        XCTAssertTrue(p.additions.isEmpty)
        XCTAssertTrue(p.newDecks.allSatisfy { $0.id != deck.id })
    }

    func testRowsWithNoDeckColumnGoToADeckNamedAfterTheFile() throws {
        let p = try plan("Front,Back,Subject\na,b,Spanish\nc,d,Spanish › Grammar", file: "Spanish vocab")
        XCTAssertEqual(p.newDecks.map(\.name), ["Spanish vocab", "Spanish vocab"])
        XCTAssertEqual(p.newDecks.map { $0.subjectID }, [p.newSubjects[0].id, p.newSubjects[1].id])
    }

    func testBlankDeckCellsFallBackToo() throws {
        let p = try plan("Front,Back,Deck\na,b,\nc,d,Verbs", file: "list")
        XCTAssertEqual(p.newDecks.map(\.name), ["list", "Verbs"])
    }

    func testTheHeaderRowIsNotACard() throws {
        let p = try plan("Front,Back\na,b")
        XCTAssertEqual(p.cardCount, 1)
        XCTAssertEqual(p.rowCount, 1)
    }

    func testDeeperThanThreeLevelsJoinsTheDeckName() throws {
        let p = try plan("Front,Back,Deck,Subject\na,b,Verbs,A › B › C › D › E")
        XCTAssertEqual(p.newSubjects.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(p.newDecks.map(\.name), ["D - E - Verbs"])
        XCTAssertEqual(p.newDecks[0].subjectID, p.newSubjects[2].id)
    }

    func testImportingInsideASubjectNestsAndRespectsItsDepth() throws {
        let top = Subject(name: "Top")
        let middle = Subject(name: "Middle", parentID: top.id)
        let library = Library(subjects: [top, middle], decks: [])

        // Inside the second level there is one level left.
        let p = try plan("Front,Back,Deck,Subject\na,b,Verbs,One › Two", library: library, context: middle.id)
        XCTAssertEqual(p.newSubjects.map(\.name), ["One"])
        XCTAssertEqual(p.newSubjects[0].parentID, middle.id)
        XCTAssertEqual(p.newDecks.map(\.name), ["Two - Verbs"])

        // A loose deck lands in the subject itself.
        let loose = try plan("Front,Back,Deck\na,b,Verbs", library: library, context: top.id)
        XCTAssertEqual(loose.newDecks[0].subjectID, top.id)
    }

    // MARK: Skipped rows

    func testSkippedRowsAreReportedInFileOrder() throws {
        let p = try plan("Front,Back\nok,fine\n,no front\nno back,\n\"broken,x\nalso ok,fine")
        XCTAssertEqual(p.cardCount, 2)
        XCTAssertEqual(p.skipped, [
            .init(rowNumber: 3, reason: .emptyFront),
            .init(rowNumber: 4, reason: .emptyBack),
            .init(rowNumber: 5, reason: .brokenQuoting),
        ])
        XCTAssertEqual(p.skipped.map(\.text), ["Row 3: empty front", "Row 4: empty back", "Row 5: quoting wasn't closed"])
        XCTAssertEqual(p.rowCount, 5)
    }

    func testPreviewShowsTheFirstFiveRowsWithProblems() throws {
        let rows = (1...8).map { "front \($0),back \($0)" }.joined(separator: "\n")
        let p = try plan("Front,Back\n,orphan\n" + rows)
        XCTAssertEqual(p.preview.count, 5)
        XCTAssertEqual(p.preview[0].problem, .emptyFront)
        XCTAssertEqual(p.preview[1].front, "front 1")
        XCTAssertEqual(p.rowCount, 9)
    }

    func testShortRowsCountAsMissingCells() throws {
        let p = try plan("Front,Back,Deck\nonly front")
        XCTAssertEqual(p.skipped, [.init(rowNumber: 2, reason: .emptyBack)])
        XCTAssertTrue(p.isEmpty)
    }

    // MARK: Several columns on a side (FLAS-97)

    private func plan(_ text: String, hasHeader: Bool = true, mapping: CSVColumnMapping,
                      destination: CSVImportDestination = .newDeck("Deck"), skipDuplicates: Bool = false,
                      library: Library = Library()) throws -> CSVImportPlan {
        let options = CSVImportOptions(hasHeader: hasHeader, mapping: mapping, destination: destination, skipDuplicates: skipDuplicates)
        return CSVImport.plan(table: try table(text), options: options, library: library, fileName: "file")
    }

    func testTwoBackColumnsJoinWithALineBreakInOrder() throws {
        let p = try plan("Word,Meaning,Example\nhablar,to speak,Hablo español.", mapping: .init(front: [0], back: [1, 2]))
        XCTAssertEqual(p.newDecks[0].cards.map(\.back), ["to speak\nHablo español."])
        let reversed = try plan("Word,Meaning,Example\nhablar,to speak,Hablo español.", mapping: .init(front: [0], back: [2, 1]))
        XCTAssertEqual(reversed.newDecks[0].cards.map(\.back), ["Hablo español.\nto speak"])
    }

    func testEmptyCellsLeaveNoBlankLines() throws {
        let p = try plan("A,B,C,D\nfront,,middle,\nx,y,,", mapping: .init(front: [0], back: [1, 2, 3]))
        XCTAssertEqual(p.newDecks[0].cards.map(\.back), ["middle", "y"], "a row with one empty and one filled back column is kept")
        XCTAssertTrue(p.skipped.isEmpty)
    }

    func testARowWithEveryBackColumnEmptyIsSkipped() throws {
        let p = try plan("A,B,C\nfront,,\n,,x", mapping: .init(front: [0], back: [1, 2]))
        XCTAssertEqual(p.skipped, [.init(rowNumber: 2, reason: .emptyBack), .init(rowNumber: 3, reason: .emptyFront)])
        XCTAssertTrue(p.isEmpty)
    }

    func testSeveralFrontColumnsJoinToo() throws {
        let p = try plan("A,B,C\nla,mesa,the table", mapping: .init(front: [0, 1], back: [2]))
        XCTAssertEqual(p.newDecks[0].cards.map(\.front), ["la\nmesa"])
    }

    func testDuplicatesCompareTheJoinedText() throws {
        let deck = Deck(name: "Travel", cards: [Card(front: "hablar", back: "to speak\nHablo.")])
        let text = "Word,Meaning,Example\nhablar,to speak,Hablo.\nhablar,to speak,Hablas."
        let p = try plan(text, mapping: .init(front: [0], back: [1, 2]), destination: .existingDeck(deck.id),
                         skipDuplicates: true, library: Library(decks: [deck]))
        XCTAssertEqual(p.duplicateCount, 1)
        XCTAssertEqual(p.additions.first?.cards.map(\.back), ["to speak\nHablas."])
    }

    func testThePreviewShowsJoinedTextOnOneLine() throws {
        let p = try plan("Word,Meaning,Example\nhablar,to speak,Hablo.", mapping: .init(front: [0], back: [1, 2]))
        XCTAssertEqual(p.preview[0].back, "to speak\nHablo.")
        XCTAssertEqual(ImportSheet.oneLine(p.preview[0].back), "to speak / Hablo.")
    }

    func testAnUnusableMappingMakesNothing() throws {
        let t = try table("only one column\nanother")
        let options = CSVImportOptions(hasHeader: false, mapping: .detect(header: nil, columnCount: 1), destination: .newDeck("x"))
        XCTAssertTrue(CSVImport.plan(table: t, options: options, library: Library(), fileName: "x").isEmpty)
    }

    // MARK: One deck

    private func deckWithCards() -> Deck {
        Deck(name: "Travel", cards: [Card(front: "hola", back: "hello"), Card(front: "adiós", back: "goodbye")])
    }

    func testAddsEverythingToAChosenDeckIgnoringStructureColumns() throws {
        let deck = deckWithCards()
        let p = try plan(sample, destination: .existingDeck(deck.id), library: Library(decks: [deck]))
        XCTAssertTrue(p.newDecks.isEmpty)
        XCTAssertTrue(p.newSubjects.isEmpty)
        XCTAssertEqual(p.additions.count, 1)
        XCTAssertEqual(p.additions[0].deckID, deck.id)
        XCTAssertEqual(p.cardCount, 5)
        XCTAssertEqual(p.openTarget, .deck(deck.id))
    }

    func testSkippingDuplicatesComparesFrontAndBack() throws {
        let deck = deckWithCards()
        let text = "Front,Back\nhola,hello\nhola,hi\nnew,card"
        let on = try plan(text, destination: .existingDeck(deck.id), skipDuplicates: true, library: Library(decks: [deck]))
        XCTAssertEqual(on.cardCount, 2)
        XCTAssertEqual(on.duplicateCount, 1)
        let off = try plan(text, destination: .existingDeck(deck.id), skipDuplicates: false, library: Library(decks: [deck]))
        XCTAssertEqual(off.cardCount, 3)
        XCTAssertEqual(off.duplicateCount, 0)
    }

    func testADeckThatIsGoneImportsNothing() throws {
        let p = try plan("Front,Back\na,b", destination: .existingDeck(UUID()))
        XCTAssertTrue(p.isEmpty)
    }

    func testANewNamedDeckIsMadeInsideTheContextSubject() throws {
        let subject = Subject(name: "Spanish")
        let p = try plan("Front,Back\na,b\nc,d", destination: .newDeck("Fresh"), library: Library(subjects: [subject]), context: subject.id)
        XCTAssertEqual(p.newDecks.map(\.name), ["Fresh"])
        XCTAssertEqual(p.newDecks[0].subjectID, subject.id)
        XCTAssertEqual(p.newDecks[0].cards.count, 2)
        XCTAssertEqual(p.openTarget, .deck(p.newDecks[0].id))
    }

    func testABlankDeckNameUsesTheFileName() throws {
        let p = try plan("Front,Back\na,b", destination: .newDeck("   "), file: "Biology")
        XCTAssertEqual(p.newDecks.map(\.name), ["Biology"])
    }

    // MARK: Words

    func testSummaryWording() throws {
        let p = try plan(sample + "\n,empty front")
        XCTAssertEqual(p.summary, "5 cards · 4 decks · 3 subjects · 1 row skipped")
        let one = try plan("Front,Back\na,b", destination: .newDeck("x"))
        XCTAssertEqual(one.summary, "1 card")
        let deck = deckWithCards()
        let dup = try plan("Front,Back\nhola,hello\nnew,card", destination: .existingDeck(deck.id), skipDuplicates: true,
                           library: Library(decks: [deck]))
        XCTAssertEqual(dup.summary, "1 card · 1 already there")
    }

    func testOpenTargetPrefersTheFirstTopLevelSubject() throws {
        let p = try plan(sample)
        XCTAssertEqual(p.openTarget, .subject(p.newSubjects[0].id))
        let loose = try plan("Front,Back,Deck\na,b,Only")
        XCTAssertEqual(loose.openTarget, .deck(loose.newDecks[0].id))
        XCTAssertNil(CSVImportPlan().openTarget)
    }

    func testAFiveThousandRowFilePlansQuickly() throws {
        let rows = (0..<5_000).map { "front \($0),back \($0),Deck \($0 % 20),Subject \($0 % 4) › Part \($0 % 3)" }
        let started = Date()
        let p = try plan("Front,Back,Deck,Subject\n" + rows.joined(separator: "\n"))
        XCTAssertEqual(p.cardCount, 5_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }
}

@MainActor
final class CSVImportStoreTests: XCTestCase {
    private var directory: URL!
    private var undo: UndoManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        undo = UndoManager()
        undo.groupsByEvent = false
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func makeStore(_ library: Library) throws -> DeckStore {
        try DeckStorage(directory: directory).save(library)
        let store = DeckStore(storage: DeckStorage(directory: directory), debounce: .milliseconds(1), onSaved: {})
        store.undoManager = undo
        return store
    }

    private func plan(_ text: String, destination: CSVImportDestination, library: Library) throws -> CSVImportPlan {
        let table = try CSVTable.read(Data(text.utf8)).get()
        let header = table.looksLikeHeader
        let options = CSVImportOptions(
            hasHeader: header,
            mapping: .detect(header: header ? table.rows.first?.fields : nil, columnCount: table.columnCount),
            destination: destination
        )
        return CSVImport.plan(table: table, options: options, library: library, fileName: "file")
    }

    func testAStructureImportIsOneUndoStep() throws {
        let existing = Deck(name: "Mine", cards: [Card(front: "keep", back: "me")])
        let library = Library(subjects: [], decks: [existing])
        let store = try makeStore(library)
        let p = try plan(
            "Front,Back,Deck,Subject\na,b,Verbs,Spanish › Grammar\nc,d,Loose,", destination: .fromFile, library: library
        )

        XCTAssertTrue(store.performImport(p))
        XCTAssertEqual(store.subjects.map(\.name), ["Spanish", "Grammar"])
        XCTAssertEqual(store.decks.map(\.name), ["Mine", "Verbs", "Loose"])
        XCTAssertEqual(undo.undoActionName, "Import")

        undo.undo()
        XCTAssertTrue(store.subjects.isEmpty)
        XCTAssertEqual(store.decks.map(\.name), ["Mine"])
        XCTAssertFalse(undo.canUndo, "one step took all of it back")

        undo.redo()
        XCTAssertEqual(store.subjects.map(\.name), ["Spanish", "Grammar"])
        XCTAssertEqual(store.decks.map(\.name), ["Mine", "Verbs", "Loose"])
        XCTAssertEqual(store.decks[1].cards.map(\.front), ["a"])
    }

    func testCardsAddedToAnExistingDeckComeBackOutAndKeepLaterEdits() throws {
        let deck = Deck(name: "Travel", cards: [Card(front: "hola", back: "hello")])
        let library = Library(decks: [deck])
        let store = try makeStore(library)
        let p = try plan("Front,Back\none,uno\ntwo,dos", destination: .existingDeck(deck.id), library: library)

        XCTAssertTrue(store.performImport(p))
        XCTAssertEqual(store.decks[0].cards.map(\.front), ["hola", "one", "two"])

        // An edit made after the import survives undoing it.
        undo.beginUndoGrouping()
        store.renameDeck(deck.id, to: "Travel phrases")
        undo.endUndoGrouping()
        undo.undo() // the rename isn't undoable (not structural): nothing registered
        undo.undo() // the import
        XCTAssertEqual(store.decks[0].cards.map(\.front), ["hola"])
        XCTAssertEqual(store.decks[0].name, "Travel phrases")

        undo.redo()
        XCTAssertEqual(store.decks[0].cards.map(\.front), ["hola", "one", "two"])
    }

    func testNothingToImportChangesNothing() throws {
        let store = try makeStore(Library())
        XCTAssertFalse(store.performImport(CSVImportPlan()))
        XCTAssertFalse(undo.canUndo)
    }

    func testImportedLibrarySavesAndReloads() async throws {
        let library = Library()
        let store = try makeStore(library)
        let p = try plan("Front,Back,Deck,Subject\na,b,Verbs,Spanish", destination: .fromFile, library: library)
        store.performImport(p)
        await store.pendingSave?.value
        let reloaded = DeckStorage(directory: directory).loadLibrary()
        XCTAssertEqual(reloaded.subjects.map(\.name), ["Spanish"])
        XCTAssertEqual(reloaded.decks.map(\.name), ["Verbs"])
        XCTAssertEqual(reloaded.decks[0].subjectID, reloaded.subjects[0].id)
    }
}

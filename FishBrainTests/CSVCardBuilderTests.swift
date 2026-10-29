import XCTest

/// Step 1 of a CSV import, "Build your card" (FLAS-96 to FLAS-99).
final class CSVCardBuilderTests: XCTestCase {
    private let vocab = """
    Word,Meaning,Example,Level
    hablar,to speak,Hablo español.,A1
    comer,to eat,Como pan.,A1
    """

    private func builder(_ text: String, file: String = "Spanish verbs") throws -> CSVCardBuilder {
        CSVCardBuilder(table: try CSVTable.read(Data(text.utf8)).get(), fileName: file)
    }

    private func plan(_ b: CSVCardBuilder, destination: CSVImportDestination? = nil) -> CSVImportPlan {
        let options = CSVImportOptions(hasHeader: b.hasHeader, mapping: b.mapping, destination: destination ?? .newDeck(b.deckName))
        return CSVImport.plan(table: b.table, options: options, library: Library(), fileName: b.deckName)
    }

    // MARK: Opening

    func testCSVOpensOnStepOneAndAnkiOnItsPreview() {
        XCTAssertTrue(ImportSheet.opensOnBuildStep(URL(fileURLWithPath: "/tmp/words.csv")))
        XCTAssertTrue(ImportSheet.opensOnBuildStep(URL(fileURLWithPath: "/tmp/words.TSV")))
        XCTAssertTrue(ImportSheet.opensOnBuildStep(URL(fileURLWithPath: "/tmp/words.txt")))
        XCTAssertFalse(ImportSheet.opensOnBuildStep(URL(fileURLWithPath: "/tmp/deck.apkg")))
    }

    func testASimpleFileIsBuiltWhenTheStepOpens() throws {
        let b = try builder(vocab)
        XCTAssertTrue(b.hasHeader)
        XCTAssertEqual(b.columns(on: .front), [0])
        XCTAssertEqual(b.columns(on: .back), [1, 2])
        XCTAssertNil(b.problem(), "one click on Next")
        XCTAssertEqual(b.activeSide, .back, "the front already has a column")
    }

    func testAOneColumnFileOpensWithTheBackToChoose() throws {
        let b = try builder("only\nanother")
        XCTAssertEqual(b.columns(on: .front), [0])
        XCTAssertEqual(b.columns(on: .back), [])
        XCTAssertEqual(b.activeSide, .back)
        XCTAssertEqual(b.problem(), "Choose a column for the back.")
    }

    func testDeckNameComesFromTheFileName() {
        XCTAssertEqual(CSVCardBuilder.deckName(forFile: URL(fileURLWithPath: "/Users/me/Spanish verbs.csv")), "Spanish verbs")
    }

    // MARK: Adding and removing

    func testAddingAndRemovingChips() throws {
        var b = try builder(vocab)
        b.activeSide = .front
        XCTAssertEqual(b.add(3), "Level added to the front")
        XCTAssertEqual(b.columns(on: .front), [0, 3])
        XCTAssertEqual(b.remove(0), "Word removed from the front")
        XCTAssertEqual(b.columns(on: .front), [3])
        XCTAssertNil(b.remove(0), "not on the card")
    }

    func testAUsedColumnCannotBeAddedTwice() throws {
        var b = try builder(vocab)
        XCTAssertFalse(b.canAdd(1))
        b.activeSide = .front
        XCTAssertNil(b.add(1))
        XCTAssertEqual(b.columns(on: .front), [0])
        XCTAssertEqual(b.columns(on: .back), [1, 2])
    }

    func testTheDeckColumnComesOffTheCardAndCannotBeAdded() throws {
        var b = try builder(vocab)
        b.setDeckColumn(2)
        XCTAssertEqual(b.columns(on: .back), [1])
        XCTAssertFalse(b.canAdd(2))
        XCTAssertNil(b.add(2))
        XCTAssertNil(b.move(2, to: .front, at: 0))
        XCTAssertEqual(b.deckNameTitle, "Deck name for rows without one")
        XCTAssertEqual(b.deckNameDetail(cardCount: 2), "Other rows go to the deck their Deck column names.")
        b.setDeckColumn(nil)
        XCTAssertTrue(b.canAdd(2))
        XCTAssertEqual(b.deckNameTitle, "Deck name")
        XCTAssertEqual(b.deckNameDetail(cardCount: 212), "All 212 cards go to a new deck with this name.")
    }

    // MARK: Moving

    func testDraggingWithinASideAndBetweenSides() throws {
        var b = try builder(vocab)
        // Example (2) dropped before Meaning (1) on the back.
        b.move(2, to: .back, at: 0)
        XCTAssertEqual(b.columns(on: .back), [2, 1])
        // Meaning dropped at the end of the front.
        b.move(1, to: .front, at: 1)
        XCTAssertEqual(b.columns(on: .front), [0, 1])
        XCTAssertEqual(b.columns(on: .back), [2])
        // A column from the file's chips dropped on the card is added there.
        b.move(3, to: .front, at: 0)
        XCTAssertEqual(b.columns(on: .front), [3, 0, 1])
        // Dropping a chip after itself changes nothing.
        XCTAssertNil(b.move(3, to: .front, at: 1))
    }

    func testMoveShortcutsChangeTheOrder() throws {
        var b = try builder(vocab)
        XCTAssertEqual(b.moveLater(1), "Meaning moved to the back, 2 of 2")
        XCTAssertEqual(b.columns(on: .back), [2, 1])
        XCTAssertNil(b.moveLater(1), "already last")
        XCTAssertEqual(b.moveEarlier(1), "Meaning moved to the back, 1 of 2")
        XCTAssertEqual(b.columns(on: .back), [1, 2])
        XCTAssertNil(b.moveEarlier(1), "already first")
        XCTAssertEqual(b.moveToOtherSide(2), "Example moved to the front, 2 of 2")
        XCTAssertEqual(b.columns(on: .front), [0, 2])
        XCTAssertEqual(b.columns(on: .back), [1])
    }

    // MARK: Skip the first row

    func testSkipTheFirstRowChangesNamesValuesCountsAndCards() throws {
        var b = try builder(vocab)
        XCTAssertEqual(b.title(1), "Meaning")
        XCTAssertEqual(b.firstValue(1), "to speak")
        XCTAssertEqual(b.rowCount, 2)
        XCTAssertEqual(b.firstRowDetail, "It holds the column names: Word, Meaning, Example…")
        XCTAssertEqual(plan(b).cardCount, 2)

        b.setSkipsFirstRow(false)
        XCTAssertEqual(b.title(1), "Column 2")
        XCTAssertEqual(b.firstValue(1), "Meaning")
        XCTAssertEqual(b.rowCount, 3)
        XCTAssertEqual(b.firstRowDetail, "The first row becomes a card: Word, Meaning, Example…")
        XCTAssertEqual(plan(b).cardCount, 3, "row 1 is imported")
        XCTAssertEqual(plan(b).newDecks[0].cards[0].front, "Word")
    }

    func testTogglingSkipTheFirstRowGuessesAgain() throws {
        var b = try builder(vocab)
        b.setSkipsFirstRow(false)
        XCTAssertEqual(b.columns(on: .front), [0])
        XCTAssertEqual(b.columns(on: .back), [1], "no names: the first two columns")
        b.setSkipsFirstRow(true)
        XCTAssertEqual(b.columns(on: .back), [1, 2])
    }

    func testAFileWithoutNamesStartsWithTheFirstRowKept() throws {
        let b = try builder("hola,hello\nla mesa,the table")
        XCTAssertFalse(b.hasHeader)
        XCTAssertEqual(b.columns(on: .front), [0])
        XCTAssertEqual(b.columns(on: .back), [1])
        XCTAssertEqual(b.titles, ["Column 1", "Column 2"])
    }

    // MARK: The deck name

    func testTheDeckNameNamesTheNewDeckAndIsTheFallback() throws {
        var b = try builder(vocab)
        XCTAssertEqual(b.deckName, "Spanish verbs")
        XCTAssertEqual(plan(b).newDecks.map(\.name), ["Spanish verbs"])

        let withDecks = try builder("Front,Back,Deck\na,b,\nc,d,Verbs", file: "Mixed")
        XCTAssertEqual(withDecks.deckColumn, 2)
        XCTAssertEqual(plan(withDecks, destination: .fromFile).newDecks.map(\.name), ["Mixed", "Verbs"])

        b.deckName = "Renamed"
        XCTAssertEqual(plan(b).newDecks.map(\.name), ["Renamed"], "step 2 reads the same name")
    }

    func testNextIsRefusedUntilTheCardAndNameAreThere() throws {
        var b = try builder(vocab)
        b.deckName = "   "
        XCTAssertEqual(b.problem(), "Give the deck a name.")
        XCTAssertNil(b.problem(needsDeckName: false), "adding to a deck that exists needs no name")
        b.deckName = "Verbs"
        b.remove(0)
        XCTAssertEqual(b.problem(), "Choose a column for the front.")
        b.activeSide = .front
        b.add(3)
        b.remove(1)
        b.remove(2)
        XCTAssertEqual(b.problem(), "Choose a column for the back.")
        b.activeSide = .back
        b.add(1)
        XCTAssertNil(b.problem())
    }

    // MARK: Keyboard and VoiceOver (FLAS-99)

    func testAKeyboardOnlyPathReachesStepTwo() throws {
        // Starting from nothing on the card: Front area (Space), Word chip (Space), Back area (Space),
        // Meaning and Example chips (Space), then Return.
        var b = try builder("hablar,to speak,Hablo español.")
        b.remove(0)
        b.remove(1)
        XCTAssertNotNil(b.problem())
        b.activeSide = .front
        b.add(0)
        b.activeSide = .back
        b.add(1)
        b.add(2)
        XCTAssertNil(b.problem())
        XCTAssertEqual(plan(b).newDecks[0].cards.map(\.back), ["to speak\nHablo español."])
    }

    func testAccessibilityLabels() throws {
        var b = try builder(vocab)
        b.activeSide = .front
        XCTAssertEqual(b.areaLabel(.front), "Front, 1 column, Word. Adding here.")
        XCTAssertEqual(b.areaLabel(.back), "Back, 2 columns, Meaning, Example.")
        XCTAssertEqual(b.columnChipLabel(3), "Add Level to the front")
        XCTAssertEqual(b.columnChipLabel(1), "Meaning, already on the card")
        XCTAssertEqual(b.cardChipLabel(1), "Meaning on the back, first value: to speak. Remove.")
        b.activeSide = .back
        XCTAssertEqual(b.columnChipLabel(3), "Add Level to the back")
        b.remove(0)
        XCTAssertEqual(b.areaLabel(.front), "Front, no columns.")
    }
}

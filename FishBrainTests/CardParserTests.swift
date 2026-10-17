import XCTest

final class CardParserTests: XCTestCase {
    private func parse(_ text: String) -> CardParseResult { CardParser.parse(text) }

    private func pairs(_ text: String) -> [[String]] {
        parse(text).cards.map { [$0.front, $0.back] }
    }

    // MARK: Separators

    func testCommaSeparatedLines() {
        XCTAssertEqual(pairs("hola, hello\nadiós,goodbye"), [["hola", "hello"], ["adiós", "goodbye"]])
    }

    func testTabSeparatedLines() {
        XCTAssertEqual(pairs("la mesa\tthe table\nel libro\tthe book"), [["la mesa", "the table"], ["el libro", "the book"]])
    }

    func testTabWinsSoCommasInTextSurviveSpreadsheetPastes() {
        XCTAssertEqual(pairs("hola, amigo\thello, friend"), [["hola, amigo", "hello, friend"]])
    }

    func testMixedSeparatorsAcrossLines() {
        XCTAssertEqual(pairs("a,b\nc\td"), [["a", "b"], ["c", "d"]])
    }

    // MARK: Quoting

    func testQuotedFieldsMayContainCommas() {
        XCTAssertEqual(pairs(#""hola, amigo", "hello, friend""#), [["hola, amigo", "hello, friend"]])
        XCTAssertEqual(pairs(#""hola, amigo","hello, friend""#), [["hola, amigo", "hello, friend"]], "no space after the comma")
        XCTAssertEqual(pairs(#"plain, "has, a comma""#), [["plain", "has, a comma"]], "only one side quoted")
    }

    func testEscapedQuotesInsideQuotedFields() {
        XCTAssertEqual(pairs(#""say ""hi""", "decir ""hola""""#), [[#"say "hi""#, #"decir "hola""#]])
    }

    func testQuotesInTheMiddleOfAnUnquotedFieldAreLiteral() {
        XCTAssertEqual(pairs(#"5" pipe, cinco pulgadas"#), [[#"5" pipe"#, "cinco pulgadas"]])
    }

    func testBrokenQuotingSkipsOnlyThatLine() {
        let result = parse("good, line\n\"unterminated, line\n\"a\"b, c\nalso, good")
        XCTAssertEqual(result.cards.map(\.front), ["good", "also"])
        XCTAssertEqual(result.skippedLines, 2)
    }

    // MARK: Whitespace, blanks and invalid lines

    func testTrimsWhitespaceAroundFields() {
        XCTAssertEqual(pairs("   hola   ,   hello   "), [["hola", "hello"]])
        XCTAssertEqual(pairs(#"  "hola"  ,  "hello"  "#), [["hola", "hello"]])
    }

    func testBlankLinesAreIgnoredNotCounted() {
        let result = parse("\n  \na, b\n\t\n\nc, d\n")
        XCTAssertEqual(result.cards.count, 2)
        XCTAssertEqual(result.skippedLines, 0)
    }

    func testLinesWithoutASeparatorOrWithAnEmptySideAreSkippedAndCounted() {
        let result = parse("just one column\nfront only,\n,back only\n\"\", \"\"\nok, fine")
        XCTAssertEqual(result.cards, [ParsedCard(front: "ok", back: "fine")])
        XCTAssertEqual(result.skippedLines, 4)
    }

    func testExtraColumnsAreIgnored() {
        XCTAssertEqual(pairs("a, b, c, d"), [["a", "b"]])
        XCTAssertEqual(pairs("a\tb\tnotes"), [["a", "b"]])
    }

    func testTrailingDelimiterIsHarmless() {
        XCTAssertEqual(pairs("a, b,"), [["a", "b"]])
    }

    // MARK: Line endings and encoding

    func testHandlesWindowsAndOldMacLineEndings() {
        XCTAssertEqual(pairs("a,b\r\nc,d\re,f"), [["a", "b"], ["c", "d"], ["e", "f"]])
    }

    func testIgnoresAByteOrderMark() {
        XCTAssertEqual(pairs("\u{FEFF}a,b"), [["a", "b"]])
    }

    func testPreservesUnicode() {
        XCTAssertEqual(pairs("日本語, Japanese 🇯🇵\nñandú, rhea"), [["日本語", "Japanese 🇯🇵"], ["ñandú", "rhea"]])
    }

    // MARK: Header

    func testAFrontBackHeaderLineIsIgnoredOnlyAsTheFirstLine() {
        XCTAssertEqual(pairs("Front, Back\na, b"), [["a", "b"]])
        XCTAssertEqual(pairs("FRONT\tBACK\na\tb"), [["a", "b"]])
        XCTAssertEqual(parse("Front, Back\na, b").skippedLines, 0)
        XCTAssertEqual(pairs("a, b\nFront, Back"), [["a", "b"], ["Front", "Back"]], "later lines are real cards")
    }

    // MARK: Whole inputs

    func testEmptyInputFindsNothing() {
        XCTAssertEqual(parse(""), CardParseResult(cards: [], skippedLines: 0))
        XCTAssertEqual(parse("  \n\n "), CardParseResult(cards: [], skippedLines: 0))
    }

    func testRealisticPaste() {
        let text = [
            "Front, Back",
            "hola, hello",
            #""hola, amigo", "hello, friend""#,
            "",
            "la mesa\tthe table",
            "this line has no separator",
            #""say ""hi""", decir hola"#,
        ].joined(separator: "\n")
        let result = parse(text)
        XCTAssertEqual(result.cards.map(\.front), ["hola", "hola, amigo", "la mesa", #"say "hi""#])
        XCTAssertEqual(result.cards.map(\.back), ["hello", "hello, friend", "the table", "decir hola"])
        XCTAssertEqual(result.skippedLines, 1)
    }
}

final class PasteSummaryTests: XCTestCase {
    func testSummaryText() {
        XCTAssertEqual(PasteSummary.text(found: 0, skipped: 0), "No cards found")
        XCTAssertEqual(PasteSummary.text(found: 1, skipped: 0), "1 card found")
        XCTAssertEqual(PasteSummary.text(found: 12, skipped: 0), "12 cards found")
        XCTAssertEqual(PasteSummary.text(found: 12, skipped: 1), "12 cards found, 1 line skipped")
        XCTAssertEqual(PasteSummary.text(found: 0, skipped: 3), "No cards found, 3 lines skipped")
    }
}

@MainActor
final class BulkAddTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAddCardsAppendsInOrderAsOneEditAndOneSave() async throws {
        let deck = Deck(name: "D", cards: [Card(front: "existing", back: "card")])
        let storage = DeckStorage(directory: directory)
        try storage.save([deck])
        var reloads = 0
        let store = DeckStore(storage: storage, debounce: .milliseconds(10), onSaved: { reloads += 1 })

        let added = store.addCards(CardParser.parse("a, 1\nb, 2\nc, 3").cards, to: deck.id)
        await store.pendingSave?.value

        XCTAssertEqual(added, 3)
        XCTAssertEqual(store.decks[0].cards.map(\.front), ["existing", "a", "b", "c"])
        XCTAssertEqual(Set(store.decks[0].cards.map(\.id)).count, 4, "every card gets its own id")
        XCTAssertEqual(storage.load()[0].cards.count, 4)
        XCTAssertEqual(reloads, 1)
    }

    func testAddingNothingOrToAnUnknownDeckDoesNothing() throws {
        let storage = DeckStorage(directory: directory)
        try storage.save([Deck(name: "D")])
        let store = DeckStore(storage: storage, debounce: .milliseconds(10), onSaved: {})

        XCTAssertEqual(store.addCards([], to: store.decks[0].id), 0)
        XCTAssertEqual(store.addCards([ParsedCard(front: "a", back: "b")], to: UUID()), 0)
        XCTAssertNil(store.pendingSave)
    }
}

import XCTest

final class CSVRecordsTests: XCTestCase {
    private func fields(_ text: String, delimiter: CSVDelimiter = .comma) -> [[String]] {
        CSVRecords.parse(text, delimiter: delimiter).records.compactMap {
            if case .fields(let f) = $0 { f } else { nil }
        }
    }

    func testPlainFieldsAreNotQuoted() {
        XCTAssertEqual(CSVRecords.escape("hola"), "hola")
        XCTAssertEqual(CSVRecords.escape("la mesa"), "la mesa")
    }

    func testFieldsWithSeparatorsQuotesOrLineBreaksAreQuoted() {
        XCTAssertEqual(CSVRecords.escape("hola, amigo"), "\"hola, amigo\"")
        XCTAssertEqual(CSVRecords.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSVRecords.escape("one\ntwo"), "\"one\ntwo\"")
        XCTAssertEqual(CSVRecords.escape("a;b"), "\"a;b\"")
        XCTAssertEqual(CSVRecords.escape("a,b"), "\"a,b\"", "every separator is quoted, so the real one is unambiguous")
        XCTAssertEqual(CSVRecords.escape("a\tb"), "\"a\tb\"")
    }

    func testRecordsAreJoinedWithCRLF() {
        XCTAssertEqual(CSVRecords.write([["a", "b"], ["c", "d"]]), "a,b\r\nc,d")
    }

    func testAQuotedFieldMayHoldLineBreaksAndCommas() {
        let text = "\"line one\nline two, with a comma\",back\r\nnext,card"
        XCTAssertEqual(fields(text), [["line one\nline two, with a comma", "back"], ["next", "card"]])
    }

    func testWriteThenParseRoundTripsAwkwardText() {
        let rows = [
            ["Front", "Back"],
            ["multi\nline", "she said \"hola\", then left"],
            ["tab\there", "semi;colon"],
            ["日本語", "🇯🇵 emoji"],
            ["", "empty front"],
        ]
        for delimiter in CSVDelimiter.allCases {
            let text = CSVRecords.write(rows, delimiter: delimiter)
            XCTAssertEqual(fields(text, delimiter: delimiter), rows, "\(delimiter)")
        }
    }

    func testAllThreeLineEndingsEndARecord() {
        XCTAssertEqual(fields("a,b\nc,d\r\ne,f\rg,h"), [["a", "b"], ["c", "d"], ["e", "f"], ["g", "h"]])
    }

    func testBlankLinesAndATrailingNewlineMakeNoRecords() {
        XCTAssertEqual(fields("\n\na,b\n\n  \nc,d\r\n"), [["a", "b"], ["c", "d"]])
    }

    func testABrokenRecordSkipsOnlyItsFirstLine() {
        let parsed = CSVRecords.parse("good,line\n\"unterminated,line\nalso,good", delimiter: .comma).records
        XCTAssertEqual(parsed, [.fields(["good", "line"]), .broken, .fields(["also", "good"])])
    }

    func testDelimiterDetection() {
        XCTAssertEqual(CSVRecords.detectDelimiter("a\tb"), .tab)
        XCTAssertEqual(CSVRecords.detectDelimiter("a;b"), .semicolon)
        XCTAssertEqual(CSVRecords.detectDelimiter("a,b"), .comma)
        XCTAssertEqual(CSVRecords.detectDelimiter("\n\nFront;Back"), .semicolon, "looks at the first non-blank line")
        XCTAssertEqual(CSVRecords.detectDelimiter("\"a;b;c\",d"), .comma, "separators inside quotes don't count")
        XCTAssertEqual(CSVRecords.detectDelimiter("5\" pipe\tcinco, pulgadas"), .tab, "a quote inside a field isn't a quoted field")
        XCTAssertEqual(CSVRecords.detectDelimiter("uno; dos; tres,three\nfour,cuatro\nfive,cinco"), .comma, "stray semicolons in a comma file")
        XCTAssertEqual(CSVRecords.detectDelimiter("uno, dos;three\nfour;cuatro\nfive;cinco"), .semicolon, "stray commas in a semicolon file")
        XCTAssertEqual(CSVRecords.detectDelimiter("\"multi\nline\"\tback"), .tab, "looks past a line break inside quotes")
        XCTAssertEqual(CSVRecords.detectDelimiter("nothing here"), .comma)
        XCTAssertEqual(CSVRecords.detectDelimiter(""), .comma)
    }
}

final class CardParserRecordTests: XCTestCase {
    func testAQuotedFrontMayHaveALineBreak() {
        let result = CardParser.parse("\"first line\nsecond line\",answer\nplain,card")
        XCTAssertEqual(result.cards.map(\.front), ["first line\nsecond line", "plain"])
        XCTAssertEqual(result.skippedLines, 0)
    }

    func testSemicolonFilesAreReadOnlyWhenAllowed() {
        let text = "Front;Back\nhola;hello\nla mesa;the table"
        XCTAssertEqual(CardParser.parse(text, isFile: true).cards.count, 2)
        // Pasted text keeps its old rules: a semicolon is just a character.
        let pasted = CardParser.parse("one; two")
        XCTAssertEqual(pasted.cards, [])
        XCTAssertEqual(pasted.skippedLines, 1)
    }

    func testTheImporterReadsSemicolonAndMultiLineFiles() throws {
        let data = Data("Front;Back\r\n\"hola\namigo\";hello\r\nla mesa;the table\r\n".utf8)
        let imported = try CardImporter.read(data).get()
        XCTAssertEqual(imported.cards, [
            ParsedCard(front: "hola\namigo", back: "hello"),
            ParsedCard(front: "la mesa", back: "the table"),
        ])
    }
}

final class LibraryExportTests: XCTestCase {
    private let spanish = Subject(name: "Spanish")
    private lazy var grammar = Subject(name: "Grammar", parentID: spanish.id)
    private lazy var verbs = Subject(name: "Verbs", parentID: grammar.id)

    private func card(_ front: String, _ back: String) -> Card { Card(front: front, back: back) }

    private lazy var subjects = [spanish, grammar, verbs]
    private lazy var decks: [Deck] = [
        Deck(name: "Phrases", cards: [card("hola", "hello")], subjectID: spanish.id),
        Deck(name: "Regular", cards: [card("hablar", "to speak"), card("comer", "to eat")], subjectID: verbs.id),
        Deck(name: "Tenses", cards: [card("pretérito", "preterite")], subjectID: grammar.id),
        Deck(name: "Loose, deck", cards: [card("a", "b")]),
    ]

    private func text(_ export: CSVExport) -> String {
        String(decoding: export.data.dropFirst(3), as: UTF8.self)
    }

    private func lines(_ export: CSVExport) -> [String] {
        text(export).components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    // MARK: A deck

    func testADeckIsWrittenWithAByteOrderMarkAndHeader() {
        let draft = ExportDraft(target: .deck(decks[1].id))
        let export = LibraryExport.csv(for: draft, subjects: subjects, decks: decks)
        XCTAssertEqual(Array(export.data.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(lines(export), ["Front,Back", "hablar,to speak", "comer,to eat"])
        XCTAssertEqual(export.cardCount, 2)
        XCTAssertEqual(export.deckCount, 1)
    }

    func testADeckCanCarryItsFullPath() {
        var draft = ExportDraft(target: .deck(decks[1].id))
        draft.options.includesStructure = true
        let export = LibraryExport.csv(for: draft, subjects: subjects, decks: decks)
        XCTAssertEqual(lines(export), [
            "Front,Back,Deck,Subject",
            "hablar,to speak,Regular,Spanish › Grammar › Verbs",
            "comer,to eat,Regular,Spanish › Grammar › Verbs",
        ])
    }

    func testOptionsChangeSeparatorAndHeader() {
        var draft = ExportDraft(target: .deck(decks[1].id))
        draft.options.delimiter = .semicolon
        draft.options.includesHeader = false
        XCTAssertEqual(lines(LibraryExport.csv(for: draft, subjects: subjects, decks: decks)), ["hablar;to speak", "comer;to eat"])
        draft.options.delimiter = .tab
        XCTAssertEqual(lines(LibraryExport.csv(for: draft, subjects: subjects, decks: decks)), ["hablar\tto speak", "comer\tto eat"])
    }

    // MARK: A subject

    func testASubjectAlwaysCarriesDeckAndSubjectColumns() {
        var draft = ExportDraft(target: .subject(spanish.id))
        draft.options.includesStructure = false
        XCTAssertTrue(draft.effectiveOptions.includesStructure)
        XCTAssertFalse(draft.structureIsOptional)
        XCTAssertTrue(ExportDraft(target: .deck(decks[0].id)).structureIsOptional)
    }

    func testASubjectIsOneFileWithPathsFromTheExportedSubjectDown() {
        let export = LibraryExport.csv(for: ExportDraft(target: .subject(spanish.id)), subjects: subjects, decks: decks)
        XCTAssertEqual(lines(export), [
            "Front,Back,Deck,Subject",
            // Sub-subjects' decks first, as the outline lists them, then the subject's own.
            "hablar,to speak,Regular,Spanish › Grammar › Verbs",
            "comer,to eat,Regular,Spanish › Grammar › Verbs",
            "pretérito,preterite,Tenses,Spanish › Grammar",
            "hola,hello,Phrases,Spanish",
        ])
        XCTAssertEqual(export.deckCount, 3)
    }

    func testAnInnerSubjectStartsItsPathsAtItself() {
        let export = LibraryExport.csv(for: ExportDraft(target: .subject(grammar.id)), subjects: subjects, decks: decks)
        XCTAssertEqual(lines(export).dropFirst().first, "hablar,to speak,Regular,Grammar › Verbs")
        XCTAssertEqual(lines(export).last, "pretérito,preterite,Tenses,Grammar")
    }

    func testUntickedDecksAreLeftOut() {
        var draft = ExportDraft(target: .subject(spanish.id))
        draft.excluded = [decks[1].id]
        let export = LibraryExport.csv(for: draft, subjects: subjects, decks: decks)
        XCTAssertEqual(export.cardCount, 2)
        XCTAssertEqual(export.deckCount, 2)
        XCTAssertFalse(text(export).contains("hablar"))
        XCTAssertEqual(draft.cardCount(subjects: subjects, decks: decks), 2)
    }

    func testTheLibraryListsSubjectsThenLooseDecks() {
        let export = LibraryExport.csv(for: ExportDraft(target: .library), subjects: subjects, decks: decks)
        XCTAssertEqual(lines(export).last, "a,b,\"Loose, deck\",")
        XCTAssertEqual(export.cardCount, 5)
    }

    func testRowsShowTheSubjectsBetweenTheExportedSubjectAndTheDeck() {
        let rows = ExportDraft(target: .subject(spanish.id)).rows(subjects: subjects, decks: decks)
        XCTAssertEqual(rows.map(\.name), ["Regular", "Tenses", "Phrases"])
        XCTAssertEqual(rows.map(\.path), ["Grammar › Verbs", "Grammar", ""])
        XCTAssertEqual(rows.map(\.cardCount), [2, 1, 1])
    }

    // MARK: Pictures

    func testPicturesAreCountedAsLeftOut() {
        var withPictures = Card(front: "f", back: "b", frontImage: CardImage(fileName: "a.jpg"), backImage: CardImage(fileName: "b.jpg"))
        withPictures.frontImage = CardImage(fileName: "a.jpg")
        let deck = Deck(name: "Pics", cards: [withPictures, Card(front: "x", back: "y", frontImage: CardImage(fileName: "c.png"))])
        let export = LibraryExport.csv(for: ExportDraft(target: .deck(deck.id)), subjects: [], decks: [deck])
        XCTAssertEqual(export.leftOutPictures, 3)
        XCTAssertEqual(ExportMessage.pictureNotice(3), "3 pictures can’t go in a CSV file.")
        XCTAssertEqual(ExportMessage.pictureNotice(1), "1 picture can’t go in a CSV file.")
        XCTAssertNil(ExportMessage.pictureNotice(0))
    }

    // MARK: Availability and names

    func testEmptySelectionsExplainThemselves() {
        let emptyDeck = Deck(name: "Empty")
        let loneSubject = Subject(name: "Lone")
        let cardless = Deck(name: "Cardless", subjectID: loneSubject.id)

        XCTAssertEqual(
            ExportDraft(target: .deck(emptyDeck.id)).unavailableReason(subjects: [], decks: [emptyDeck]),
            "This deck has no cards yet."
        )
        XCTAssertEqual(
            ExportDraft(target: .subject(loneSubject.id)).unavailableReason(subjects: [loneSubject], decks: []),
            "There are no decks in this subject yet."
        )
        XCTAssertEqual(
            ExportDraft(target: .subject(loneSubject.id)).unavailableReason(subjects: [loneSubject], decks: [cardless]),
            "There are no cards in this subject yet."
        )
        XCTAssertEqual(
            ExportDraft(target: .library).unavailableReason(subjects: [], decks: []),
            "There are no cards to export yet."
        )
        XCTAssertNil(ExportDraft(target: .subject(spanish.id)).unavailableReason(subjects: subjects, decks: decks))

        var allOff = ExportDraft(target: .subject(spanish.id))
        allOff.excluded = Set(decks.map(\.id))
        XCTAssertEqual(
            allOff.unavailableReason(subjects: subjects, decks: decks),
            "Tick at least one deck that has cards."
        )
    }

    func testFileNamesAreSafe() {
        let slashes = Deck(name: "Maths/Physics: 101")
        XCTAssertEqual(
            LibraryExport.suggestedFileName(target: .deck(slashes.id), subjects: [], decks: [slashes], format: .csv),
            "Maths-Physics- 101.csv"
        )
        XCTAssertEqual(
            LibraryExport.suggestedFileName(target: .subject(spanish.id), subjects: subjects, decks: decks, format: .csv),
            "Spanish.csv"
        )
        XCTAssertEqual(
            LibraryExport.suggestedFileName(target: .library, subjects: [], decks: [], format: .csv),
            "FishBrain Library.csv"
        )
        let dotted = Deck(name: "...")
        XCTAssertEqual(
            LibraryExport.suggestedFileName(target: .deck(dotted.id), subjects: [], decks: [dotted], format: .csv),
            "FishBrain.csv"
        )
    }

    func testBothFormatsAreAvailable() {
        XCTAssertTrue(ExportFormat.csv.isAvailable)
        XCTAssertTrue(ExportFormat.anki.isAvailable)
        XCTAssertEqual(ExportFormat.csv.fileExtension, "csv")
        XCTAssertEqual(ExportFormat.anki.fileExtension, "apkg")
    }

    func testMessages() {
        XCTAssertEqual(ExportMessage.summary(cards: 1, decks: 1), "1 card")
        XCTAssertEqual(ExportMessage.summary(cards: 412, decks: 8), "412 cards · 8 decks")
        XCTAssertEqual(ExportMessage.doneTitle(cards: 1), "Exported 1 card")
        XCTAssertEqual(ExportMessage.doneTitle(cards: 312), "Exported 312 cards")
    }

    // MARK: Round trip

    func testAnExportedDeckImportsBackWithTheSameText() throws {
        let tricky = [
            card("multi\nline front", "back, with a comma"),
            card("she said \"hola\"", "quotes"),
            card("日本語", "Japanese 🇯🇵"),
            card("tab\there", "semi;colon"),
        ]
        let deck = Deck(name: "Tricky", cards: tricky)
        for delimiter in CSVDelimiter.allCases {
            var draft = ExportDraft(target: .deck(deck.id))
            draft.options.delimiter = delimiter
            let export = LibraryExport.csv(for: draft, subjects: [], decks: [deck])
            let imported = try CardImporter.read(export.data).get()
            XCTAssertEqual(imported.cards, tricky.map { ParsedCard(front: $0.front, back: $0.back) }, "\(delimiter)")
            XCTAssertEqual(imported.skippedLines, 0)
        }
    }

    func testASubjectFileStillImportsAsFrontAndBackIntoOneDeck() throws {
        let export = LibraryExport.csv(for: ExportDraft(target: .subject(spanish.id)), subjects: subjects, decks: decks)
        let imported = try CardImporter.read(export.data).get()
        XCTAssertEqual(imported.cards.map(\.front), ["hablar", "comer", "pretérito", "hola"])
        XCTAssertEqual(imported.cards.map(\.back), ["to speak", "to eat", "preterite", "hello"])
    }

    func testAFileWithOnlyAHeaderImportsNothing() {
        var draft = ExportDraft(target: .deck(decks[0].id))
        draft.excluded = [decks[0].id]
        let export = LibraryExport.csv(for: draft, subjects: subjects, decks: decks)
        XCTAssertEqual(export.cardCount, 0)
        XCTAssertEqual(lines(export), ["Front,Back"])
        XCTAssertEqual(CardImporter.read(export.data), .failure(.noCards(skippedLines: 0)))
    }

    func testFiveThousandCardsWriteQuickly() {
        let cards = (0..<5_000).map { Card(front: "front \($0), with comma", back: "back \($0)\nsecond line") }
        let deck = Deck(name: "Big", cards: cards)
        let started = Date()
        let export = LibraryExport.csv(for: ExportDraft(target: .deck(deck.id)), subjects: [], decks: [deck])
        XCTAssertEqual(export.cardCount, 5_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }
}

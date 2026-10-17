import XCTest

final class CardImporterTests: XCTestCase {
    private func importResult(_ data: Data) -> Result<CardImport, ImportFailure> { CardImporter.read(data) }
    private func success(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> CardImport {
        try importResult(data).get()
    }

    // MARK: Parsing is shared with Paste Cards

    func testUsesTheSameParserAsPaste() throws {
        let text = "Front, Back\nhola, hello\n\"hola, amigo\", \"hello, friend\"\nla mesa\tthe table\nno separator"
        let imported = try success(Data(text.utf8))
        let pasted = CardParser.parse(text)

        XCTAssertEqual(imported.cards, pasted.cards)
        XCTAssertEqual(imported.skippedLines, pasted.skippedLines)
        XCTAssertEqual(imported.cards.count, 3)
        XCTAssertEqual(imported.skippedLines, 1)
    }

    func testCSVAndTSVBothWork() throws {
        XCTAssertEqual(try success(Data("a,1\nb,2".utf8)).cards.count, 2)
        XCTAssertEqual(try success(Data("a\t1\nb\t2".utf8)).cards.count, 2)
    }

    func testWindowsLineEndings() throws {
        XCTAssertEqual(try success(Data("a,1\r\nb,2\r\n".utf8)).cards.count, 2)
    }

    // MARK: Encodings

    func testUTF8WithAndWithoutBOM() throws {
        let plain = try success(Data("café, coffee".utf8))
        XCTAssertEqual(plain.encoding, .utf8)
        XCTAssertEqual(plain.cards.first?.front, "café")

        let bom = try success(Data([0xEF, 0xBB, 0xBF]) + Data("café, coffee".utf8))
        XCTAssertEqual(bom.encoding, .utf8)
        XCTAssertEqual(bom.cards.first?.front, "café", "the BOM is not part of the text")
    }

    func testUTF16WithBOMInBothByteOrders() throws {
        let little = try success("café, coffee".data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 }!)
        XCTAssertEqual(little.encoding, .utf16)
        XCTAssertEqual(little.cards.first, ParsedCard(front: "café", back: "coffee"))

        let big = try success("café, coffee".data(using: .utf16BigEndian).map { Data([0xFE, 0xFF]) + $0 }!)
        XCTAssertEqual(big.encoding, .utf16)
        XCTAssertEqual(big.cards.first, ParsedCard(front: "café", back: "coffee"))
    }

    func testLegacyEncodedFilesFallBackToWindowsLatin1() throws {
        // "café, coffee" as Windows Latin-1: é is the single byte 0xE9, which is not valid UTF-8.
        let data = Data([0x63, 0x61, 0x66, 0xE9, 0x2C, 0x20, 0x63, 0x6F, 0x66, 0x66, 0x65, 0x65])
        let imported = try success(data)
        XCTAssertEqual(imported.encoding, .windowsLatin1)
        XCTAssertEqual(imported.cards.first, ParsedCard(front: "café", back: "coffee"))
    }

    // MARK: Failures

    func testEmptyFileAndWhitespaceOnlyFile() {
        XCTAssertEqual(importResult(Data()), .failure(.emptyFile))
        XCTAssertEqual(importResult(Data("  \n\n\t \n".utf8)), .failure(.emptyFile))
    }

    func testBinaryDataIsNotATextFile() {
        XCTAssertEqual(importResult(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x1A, 0x0A])), .failure(.notTextFile))
        XCTAssertEqual(importResult(Data("a,b".utf8) + Data([0])), .failure(.notTextFile))
    }

    func testFileWithNoValidLinesReportsHowManyWereSkipped() {
        XCTAssertEqual(importResult(Data("one\ntwo\n\nthree".utf8)), .failure(.noCards(skippedLines: 3)))
        XCTAssertEqual(importResult(Data("Front, Back".utf8)), .failure(.noCards(skippedLines: 0)), "a header alone has no cards")
    }

    func testOversizedData() {
        XCTAssertEqual(CardImporter.read(Data(repeating: 0x61, count: 50), maxBytes: 10), .failure(.tooLarge(bytes: 50, limit: 10)))
    }

    // MARK: Files on disk

    private func tempFile(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrain-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsCSVTSVAndTXTFilesFromDisk() throws {
        for name in ["cards.csv", "cards.tsv", "cards.txt"] {
            let delimiter = name.hasSuffix("tsv") ? "\t" : ","
            let url = try tempFile(name, Data("hola\(delimiter)hello\nadiós\(delimiter)goodbye".utf8))
            let imported = try CardImporter.read(contentsOf: url).get()
            XCTAssertEqual(imported.cards.map(\.front), ["hola", "adiós"], name)
        }
    }

    func testMissingFileIsReportedAsUnreadable() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).csv")
        guard case .failure(.unreadable) = CardImporter.read(contentsOf: url) else {
            return XCTFail("expected .unreadable")
        }
    }

    func testLargeFilesAreRejectedBeforeBeingRead() throws {
        let url = try tempFile("big.csv", Data(repeating: 0x61, count: 100))
        XCTAssertEqual(CardImporter.read(contentsOf: url, maxBytes: 10), .failure(.tooLarge(bytes: 100, limit: 10)))
    }
}

final class ImportMessageTests: XCTestCase {
    private func result(cards: Int, skipped: Int = 0, encoding: TextEncoding = .utf8) -> CardImport {
        CardImport(cards: (0..<cards).map { ParsedCard(front: "f\($0)", back: "b\($0)") }, skippedLines: skipped, encoding: encoding)
    }

    func testSuccessStatesTheCountAndDeck() {
        let notice = ImportMessage.success(result(cards: 48), deckName: "Spanish")
        XCTAssertEqual(notice.title, "Imported 48 cards")
        XCTAssertEqual(notice.message, "Added to “Spanish”.")
        XCTAssertEqual(ImportMessage.success(result(cards: 1), deckName: "D").title, "Imported 1 card")
    }

    func testSuccessMentionsSkippedLinesAndNonUTF8() {
        let notice = ImportMessage.success(result(cards: 3, skipped: 2, encoding: .windowsLatin1), deckName: "D")
        XCTAssertTrue(notice.message.contains("2 lines were skipped"))
        XCTAssertTrue(notice.message.contains("isn't UTF-8"))
        XCTAssertTrue(ImportMessage.success(result(cards: 3, skipped: 1), deckName: "D").message.contains("1 line was skipped"))
    }

    func testEveryFailureExplainsItself() {
        let failures: [ImportFailure] = [
            .unreadable("Permission denied"), .tooLarge(bytes: 50_000_000, limit: 10_000_000),
            .emptyFile, .notTextFile, .noCards(skippedLines: 0), .noCards(skippedLines: 4),
        ]
        for failure in failures {
            let notice = ImportMessage.failure(failure)
            XCTAssertEqual(notice.title, "Nothing was imported")
            XCTAssertFalse(notice.message.isEmpty, "\(failure)")
        }
        XCTAssertTrue(ImportMessage.failure(.unreadable("Permission denied")).message.contains("Permission denied"))
        XCTAssertTrue(ImportMessage.failure(.noCards(skippedLines: 4)).message.contains("None of the 4 lines"))
        XCTAssertTrue(ImportMessage.failure(.notTextFile).message.contains(".csv"))
    }
}

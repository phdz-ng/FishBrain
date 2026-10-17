import XCTest

final class DeckStorageTests: XCTestCase {
    private var directory: URL!
    private var storage: DeckStorage!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = DeckStorage(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripPreservesEverythingIncludingOrder() throws {
        let decks = [
            Deck(name: "Spanish 🇪🇸", color: .orange, cards: [
                Card(front: "hola", back: "hello"),
                Card(front: "¿Qué tal?\nmultiline", back: "How are you? \"quoted\" 日本語"),
                Card(front: "", back: ""),
            ]),
            Deck(name: "Empty", color: .green),
        ]
        try storage.save(decks)
        XCTAssertEqual(storage.load(), decks)
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertEqual(storage.load(), [])
    }

    func testCorruptFileFallsBackToEmptyAndIsKeptAside() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: storage.fileURL)

        XCTAssertEqual(storage.load(), [])

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.contains(DeckStorage.fileName))
        XCTAssertEqual(files.filter { $0.hasPrefix("decks.corrupt-") }.count, 1)
    }

    func testNewerFileVersionIsNotOverwrittenSilently() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version": 99, "decks": []}"#.utf8).write(to: storage.fileURL)

        XCTAssertEqual(storage.load(), [])

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("decks.corrupt-") })
    }

    func testUnknownDeckColorDecodesToDefault() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let json = #"{"version":1,"decks":[{"id":"\#(id)","name":"X","color":"chartreuse","cards":[]}]}"#
        try Data(json.utf8).write(to: storage.fileURL)

        XCTAssertEqual(storage.load().first?.color, .accent)
    }

    func testSaveCreatesMissingDirectoryAndLeavesNoTempFiles() throws {
        try storage.save([Deck(name: "A")])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, [DeckStorage.fileName])
    }
}

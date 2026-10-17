import XCTest

@MainActor
final class DeckStoreTests: XCTestCase {
    private var directory: URL!
    private var storage: DeckStorage!
    private var reloadCount = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = DeckStorage(directory: directory)
        reloadCount = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(debounce: Duration = .milliseconds(20)) -> DeckStore {
        DeckStore(storage: storage, debounce: debounce, onSaved: { [unowned self] in reloadCount += 1 })
    }

    func testEditsAreDebouncedIntoOneSaveAndReloadTheWidget() async throws {
        let store = makeStore()
        store.decks = [Deck(name: "A")]
        store.decks[0].name = "AB"
        store.decks[0].name = "ABC"

        XCTAssertEqual(storage.load(), [], "nothing written before the debounce elapses")
        await store.pendingSave?.value

        XCTAssertEqual(storage.load().first?.name, "ABC")
        XCTAssertEqual(reloadCount, 1)
    }

    func testFlushSavesImmediatelyAndCancelsPendingSave() async throws {
        let store = makeStore(debounce: .seconds(60))
        store.decks = [Deck(name: "Now")]
        store.flush()

        XCTAssertEqual(storage.load().first?.name, "Now")
        XCTAssertEqual(reloadCount, 1)
        await store.pendingSave?.value
        XCTAssertEqual(reloadCount, 1)
    }

    func testStoreLoadsExistingDecksOnInitWithoutSaving() async throws {
        try storage.save([Deck(name: "Existing")])
        let store = makeStore()

        XCTAssertEqual(store.decks.map(\.name), ["Existing"])
        XCTAssertNil(store.pendingSave)
        XCTAssertEqual(reloadCount, 0)
    }

    func testSaveFailureIsReportedNotThrown() async throws {
        // A file where the directory should be makes every save fail.
        try Data().write(to: directory)
        let store = makeStore()
        store.decks = [Deck(name: "A")]
        await store.pendingSave?.value

        XCTAssertNotNil(store.lastSaveError)
        XCTAssertEqual(reloadCount, 0)
    }
}

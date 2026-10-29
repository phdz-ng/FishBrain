import XCTest

final class SettingsStorageTests: XCTestCase {
    private var directory: URL!
    private var storage: SettingsStorage!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = SettingsStorage(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultAccentIsOrange() {
        XCTAssertEqual(AppSettings().accent, .orange)
        XCTAssertEqual(storage.load().accent, .orange, "missing file loads defaults")
    }

    func testEveryAccentRoundTrips() throws {
        for accent in AccentChoice.allCases {
            try storage.save(AppSettings(accent: accent))
            XCTAssertEqual(storage.load().accent, accent)
        }
    }

    func testCorruptFileFallsBackToDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: storage.fileURL)
        XCTAssertEqual(storage.load(), AppSettings())
    }

    func testUnknownAccentAndMissingKeysFallBackToDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"accent":"chartreuse"}"#.utf8).write(to: storage.fileURL)
        XCTAssertEqual(storage.load().accent, .orange)

        try Data("{}".utf8).write(to: storage.fileURL)
        XCTAssertEqual(storage.load().accent, .orange)
    }

    func testSettingsLiveNextToDecksInTheSameDirectory() throws {
        try storage.save(AppSettings(accent: .teal))
        try DeckStorage(directory: directory).save([Deck(name: "A")])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, [DeckStorage.fileName, SettingsStorage.fileName])
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var directory: URL!
    private var storage: SettingsStorage!
    private var reloads = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = SettingsStorage(directory: directory)
        reloads = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(storage: storage, onSaved: { [unowned self] in reloads += 1 })
    }

    func testChoicePersistsAndIsVisibleToTheWidgetsReader() {
        let store = makeStore()
        store.accent = .purple

        // The widget extension reads through its own storage instance on the same container.
        XCTAssertEqual(SettingsStorage(directory: directory).load().accent, .purple)
        // And a fresh app launch restores it.
        XCTAssertEqual(makeStore().accent, .purple)
    }

    func testChangingAccentReloadsWidgetsExactlyOncePerChange() {
        let store = makeStore()
        XCTAssertEqual(reloads, 0, "loading does not reload")

        store.accent = .blue
        XCTAssertEqual(reloads, 1)
        store.accent = .blue
        XCTAssertEqual(reloads, 1, "setting the same value is a no-op")
        store.accent = .teal
        XCTAssertEqual(reloads, 2)
    }

    func testSaveFailureIsReportedAndDoesNotReloadWidgets() throws {
        try Data().write(to: directory) // a file where the directory should be
        let store = makeStore()
        store.accent = .teal

        XCTAssertNotNil(store.lastSaveError)
        XCTAssertEqual(reloads, 0)
    }
}

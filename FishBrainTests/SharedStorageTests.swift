import XCTest

final class SharedStorageLocationTests: XCTestCase {
    private let shared = URL(fileURLWithPath: "/Users/someone/Library/Application Support/FishBrain")
    private let teamID = "ABCDE12345.io.github.phdz-ng.fishbrain"
    private let plainID = "io.github.phdz-ng.fishbrain"
    private let group = URL(fileURLWithPath: "/Users/someone/Library/Group Containers/ABCDE12345.io.github.phdz-ng.fishbrain")

    private func resolve(_ identifier: String, _ container: URL?) -> URL {
        AppGroup.resolveStorageDirectory(identifier: identifier, container: container, shared: shared)
    }

    func testATeamSignedBuildUsesItsRealGroupContainer() {
        XCTAssertEqual(resolve(teamID, group), group)
    }

    /// Without a team the widget can be handed an empty "Group Containers" folder for the same ID
    /// while the app is handed its private folder; both must use the shared folder instead.
    func testWithoutATeamAGroupContainerIsStillNotTrusted() {
        let emptyGroup = URL(fileURLWithPath: "/Users/someone/Library/Group Containers/io.github.phdz-ng.fishbrain")
        XCTAssertEqual(resolve(plainID, emptyGroup), shared)
    }

    func testTheAppsOwnPrivateFolderIsNeverTreatedAsShared() {
        let own = URL(fileURLWithPath: "/Users/someone/Library/Containers/io.github.phdz-ng.fishbrain/Data")
        XCTAssertEqual(resolve(plainID, own), shared)
        XCTAssertEqual(resolve(teamID, own), shared)
    }

    func testNoContainerFallsBackToTheSharedFolder() {
        XCTAssertEqual(resolve(teamID, nil), shared)
        XCTAssertEqual(resolve(plainID, nil), shared)
        XCTAssertEqual(resolve("", nil), shared)
    }

    func testAppAndWidgetAlwaysAgreeWithoutATeam() {
        // Whatever each process is handed, the answer is the same folder.
        let handedToApp = URL(fileURLWithPath: "/Users/someone/Library/Containers/io.github.phdz-ng.fishbrain/Data")
        let handedToWidget = URL(fileURLWithPath: "/Users/someone/Library/Group Containers/io.github.phdz-ng.fishbrain")
        XCTAssertEqual(resolve(plainID, handedToApp), resolve(plainID, handedToWidget))
    }

    func testTeamPrefixDetection() {
        XCTAssertTrue(AppGroup.isTeamPrefixed("ABCDE12345.io.github.phdz-ng.fishbrain"))
        XCTAssertTrue(AppGroup.isTeamPrefixed("9A8B7C6D5E.group.example"))
        XCTAssertFalse(AppGroup.isTeamPrefixed("io.github.phdz-ng.fishbrain"))
        XCTAssertFalse(AppGroup.isTeamPrefixed("abcde12345.io.github"), "lowercase isn't a team ID")
        XCTAssertFalse(AppGroup.isTeamPrefixed("ABCDE1234.io.github"), "too short")
        XCTAssertFalse(AppGroup.isTeamPrefixed(""))
    }

    func testTheSharedFolderIsUnderTheRealHomeNotTheSandboxContainer() {
        XCTAssertTrue(AppGroup.sharedDirectory.path.hasSuffix("/Library/Application Support/FishBrain"))
        XCTAssertFalse(AppGroup.sharedDirectory.path.contains("/Library/Containers/"))
    }
}

final class StorageMigrationTests: XCTestCase {
    private var root: URL!
    private var legacy: URL!
    private var other: URL!
    private var target: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        legacy = root.appendingPathComponent("legacy")
        other = root.appendingPathComponent("other")
        target = root.appendingPathComponent("target")
        for dir in [legacy!, other!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func read(_ name: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    func testCopiesTheLibraryFromAnOldLocation() throws {
        try write("decks", DeckStorage.fileName, in: legacy)
        try write("playback", PlaybackStorage.fileName, in: legacy)

        let copied = StorageMigration.copyMissingFiles(from: [legacy], to: target)

        XCTAssertEqual(Set(copied), [DeckStorage.fileName, PlaybackStorage.fileName])
        XCTAssertEqual(read(DeckStorage.fileName, in: target), "decks")
        XCTAssertEqual(read(PlaybackStorage.fileName, in: target), "playback")
        XCTAssertNil(read(SettingsStorage.fileName, in: target), "nothing to copy for a file that doesn't exist")
    }

    private func setDate(_ date: Date, _ name: String, in dir: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dir.appendingPathComponent(name).path)
    }

    func testDoesNotOverwriteATargetThatIsNewerOrEqual() throws {
        let now = Date()
        try write("old decks", DeckStorage.fileName, in: legacy)
        try write("new decks", DeckStorage.fileName, in: target)
        try setDate(now.addingTimeInterval(-100), DeckStorage.fileName, in: legacy)
        try setDate(now, DeckStorage.fileName, in: target)

        XCTAssertEqual(StorageMigration.copyMissingFiles(from: [legacy], to: target), [])
        XCTAssertEqual(read(DeckStorage.fileName, in: target), "new decks")

        try setDate(now, DeckStorage.fileName, in: legacy) // exactly equal
        XCTAssertEqual(StorageMigration.copyMissingFiles(from: [legacy], to: target), [])
    }

    /// An old build kept saving to its private folder after an earlier copy was made.
    func testAdoptsANewerOldCopyAndKeepsABackupOfWhatItReplaces() throws {
        let now = Date()
        try write("first copy", DeckStorage.fileName, in: target)
        try write("newer cards", DeckStorage.fileName, in: legacy)
        try setDate(now.addingTimeInterval(-3600), DeckStorage.fileName, in: target)
        try setDate(now, DeckStorage.fileName, in: legacy)

        XCTAssertEqual(StorageMigration.copyMissingFiles(from: [legacy], to: target, now: now), [DeckStorage.fileName])

        XCTAssertEqual(read(DeckStorage.fileName, in: target), "newer cards")
        let files = try FileManager.default.contentsOfDirectory(atPath: target.path)
        let backups = files.filter { $0.hasPrefix("\(DeckStorage.fileName).backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(read(backups[0], in: target), "first copy", "what was replaced is kept")
        XCTAssertEqual(read(DeckStorage.fileName, in: legacy), "newer cards", "the original stays")
    }

    func testRunningTheMigrationAgainChangesNothing() throws {
        let now = Date()
        try write("first copy", DeckStorage.fileName, in: target)
        try write("newer cards", DeckStorage.fileName, in: legacy)
        try setDate(now.addingTimeInterval(-3600), DeckStorage.fileName, in: target)
        try setDate(now, DeckStorage.fileName, in: legacy)

        StorageMigration.copyMissingFiles(from: [legacy], to: target, now: now)
        XCTAssertEqual(StorageMigration.copyMissingFiles(from: [legacy], to: target, now: now), [], "the copy is no longer older")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).filter { $0.contains("backup") }.count, 1)
    }

    func testTheNewestOfSeveralOldCopiesIsAdopted() throws {
        let now = Date()
        try write("older", DeckStorage.fileName, in: legacy)
        try write("newest", DeckStorage.fileName, in: other)
        try setDate(now.addingTimeInterval(-500), DeckStorage.fileName, in: legacy)
        try setDate(now, DeckStorage.fileName, in: other)

        StorageMigration.copyMissingFiles(from: [legacy, other], to: target)
        XCTAssertEqual(read(DeckStorage.fileName, in: target), "newest")
    }

    func testLeavesTheOriginalsInPlace() throws {
        try write("decks", DeckStorage.fileName, in: legacy)
        StorageMigration.copyMissingFiles(from: [legacy], to: target)
        XCTAssertEqual(read(DeckStorage.fileName, in: legacy), "decks")
    }

    func testFilesCanComeFromDifferentSources() throws {
        try write("decks", DeckStorage.fileName, in: legacy)
        try write("settings", SettingsStorage.fileName, in: other)

        StorageMigration.copyMissingFiles(from: [legacy, other], to: target)

        XCTAssertEqual(read(DeckStorage.fileName, in: target), "decks")
        XCTAssertEqual(read(SettingsStorage.fileName, in: target), "settings")
    }

    func testASourceThatIsTheTargetItselfIsIgnored() throws {
        try write("decks", DeckStorage.fileName, in: target)
        XCTAssertEqual(StorageMigration.copyMissingFiles(from: [target], to: target), [])
        XCTAssertEqual(read(DeckStorage.fileName, in: target), "decks")
    }

    func testNothingToMigrateCreatesNothing() {
        XCTAssertEqual(StorageMigration.copyMissingFiles(from: [legacy, other], to: target), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testAMigratedLibraryLoadsThroughTheNormalStorage() throws {
        try DeckStorage(directory: legacy).save([Deck(name: "New Deck", cards: [Card(front: "a", back: "b")])])
        StorageMigration.copyMissingFiles(from: [legacy], to: target)

        let decks = DeckStorage(directory: target).load()
        XCTAssertEqual(decks.map(\.name), ["New Deck"])
        XCTAssertEqual(decks.first?.cards.count, 1)
    }
}

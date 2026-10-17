import XCTest

/// Sprint history (FLAS-60): `runs.json`, the usual pace and the last result.
private let start = Date(timeIntervalSince1970: 1_791_900_000)

private func makeRecord(
    minutes: Int = 10, reviewed: Int = 20, at offset: TimeInterval = 0, decks: [Deck.ID] = [],
    byDeck: [Deck.ID: Int] = [:], grades: RunRecord.Grades = .init(again: 2, hard: 3, good: 10, easy: 5)
) -> RunRecord {
    RunRecord(
        startedAt: start.addingTimeInterval(offset), minutes: minutes, deckIDs: decks, reviewed: reviewed,
        byDeck: Dictionary(uniqueKeysWithValues: byDeck.map { ($0.key.uuidString, $0.value) }), grades: grades
    )
}

final class RunHistoryTests: XCTestCase {
    private var directory: URL!
    private var storage: RunHistoryStorage!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = RunHistoryStorage(directory: directory)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    // MARK: Storage

    func testAMissingFileIsNoHistory() {
        XCTAssertTrue(storage.load().isEmpty)
        XCTAssertNil(storage.load().last)
        XCTAssertNil(storage.load().usualPace)
    }

    func testRoundTrip() throws {
        let a = Deck.ID(), b = Deck.ID()
        let first = makeRecord(minutes: 10, reviewed: 23, at: 0, decks: [a, b], byDeck: [a: 15, b: 8])
        let second = makeRecord(minutes: 5, reviewed: 9, at: 3_600, decks: [a], byDeck: [a: 9], grades: .init(again: 1, hard: 0, good: 6, easy: 2))
        try storage.append(first)
        try storage.append(second)

        let loaded = storage.load()
        XCTAssertEqual(loaded.runs, [first, second])
        XCTAssertEqual(loaded.last, second)
        XCTAssertEqual(loaded.last?.deckCounts, [a: 9])
        XCTAssertEqual(loaded.runs[0].deckCounts, [a: 15, b: 8])
    }

    func testTheFileHasTheDocumentedShape() throws {
        let a = Deck.ID()
        try storage.append(makeRecord(minutes: 10, reviewed: 23, decks: [a], byDeck: [a: 23], grades: .init(again: 3, hard: 4, good: 12, easy: 4)))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: storage.fileURL)) as? [String: Any]
        let runs = try XCTUnwrap(object?["runs"] as? [[String: Any]])
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(Set(run.keys), ["startedAt", "minutes", "deckIDs", "reviewed", "byDeck", "grades"])
        XCTAssertEqual(run["startedAt"] as? Double, 1_791_900_000, "seconds since 1970, as in the design")
        XCTAssertEqual(run["minutes"] as? Int, 10)
        XCTAssertEqual(run["deckIDs"] as? [String], [a.uuidString])
        XCTAssertEqual((run["byDeck"] as? [String: Int])?[a.uuidString], 23)
        let grades = try XCTUnwrap(run["grades"] as? [String: Int])
        XCTAssertEqual(grades, ["again": 3, "hard": 4, "good": 12, "easy": 4])
        XCTAssertEqual(storage.fileURL.lastPathComponent, "runs.json")
    }

    func testOnlyTheLastHundredRunsAreKept() throws {
        for i in 0..<105 { try storage.append(makeRecord(reviewed: i, at: Double(i))) }
        let history = storage.load()
        XCTAssertEqual(history.runs.count, 100)
        XCTAssertEqual(history.runs.first?.reviewed, 5, "the oldest five were dropped")
        XCTAssertEqual(history.last?.reviewed, 104)

        var pure = RunHistory(runs: (0..<130).map { makeRecord(reviewed: $0) })
        XCTAssertEqual(pure.runs.count, 100)
        pure.append(makeRecord(reviewed: 999))
        XCTAssertEqual(pure.runs.count, 100)
        XCTAssertEqual(pure.runs.first?.reviewed, 31)
    }

    func testACorruptFileIsMovedAsideAndTheHistoryStartsAgain() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ \"runs\": [ nope".utf8).write(to: storage.fileURL)

        XCTAssertTrue(storage.load().isEmpty, "never throws, never blocks a sprint")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.fileURL.path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("runs.corrupt-") }
        XCTAssertEqual(aside.count, 1, "the unreadable file is kept, not deleted")

        try storage.append(makeRecord(reviewed: 7))
        XCTAssertEqual(storage.load().runs.map(\.reviewed), [7], "and the history carries on from nothing")
    }

    func testAFileWithTheWrongShapeIsTreatedTheSame() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"runs": [{"minutes": "ten"}]}"#.utf8).write(to: storage.fileURL)
        XCTAssertTrue(storage.load().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("runs.corrupt-") }.count, 1)
    }

    func testTwoWritersLoseNothing() throws {
        let other = RunHistoryStorage(directory: directory) // another process's handle on the same file
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "writers", attributes: .concurrent)
        let lock = NSLock()
        var failures = 0
        for i in 0..<40 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do { try (i.isMultiple(of: 2) ? self.storage : other).append(makeRecord(reviewed: i, at: Double(i))) } catch {
                    lock.lock(); failures += 1; lock.unlock()
                }
            }
        }
        group.wait()
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(Set(storage.load().runs.map(\.reviewed)), Set(0..<40), "every run from both writers is there")
    }

    func testTheLibraryFileIsNotTouched() throws {
        let decks = DeckStorage(directory: directory)
        try decks.save([Deck(name: "Spanish", cards: [Card(front: "a", back: "b")])])
        let before = try Data(contentsOf: decks.fileURL)
        try storage.append(makeRecord())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: storage.fileURL)
        _ = storage.load()
        XCTAssertEqual(try Data(contentsOf: decks.fileURL), before)
    }

    // MARK: What it tells

    func testTheLastRun() {
        var history = RunHistory()
        XCTAssertNil(history.last)
        history.append(makeRecord(reviewed: 19, at: 0))
        history.append(makeRecord(reviewed: 23, at: 100))
        XCTAssertEqual(history.last?.reviewed, 23)
        XCTAssertEqual(history.resultsHistory.lastCount, 23)
        XCTAssertEqual(history.resultsHistory.lastSeconds, 600)
    }

    func testNoUsualPaceUntilThreeRunsOfAtLeastThreeMinutes() {
        var history = RunHistory()
        XCTAssertNil(history.usualPace)
        history.append(makeRecord(minutes: 10, reviewed: 20))
        history.append(makeRecord(minutes: 10, reviewed: 22))
        XCTAssertNil(history.usualPace, "two runs aren't a habit")
        history.append(makeRecord(minutes: 5, reviewed: 10))
        XCTAssertEqual(history.usualPace, 2)
        XCTAssertEqual(history.resultsHistory.usualPace, 2)
    }

    func testShortRunsAreIgnoredForThePace() {
        var history = RunHistory()
        history.append(makeRecord(minutes: 10, reviewed: 20))
        history.append(makeRecord(minutes: 10, reviewed: 30))
        history.append(makeRecord(minutes: 2, reviewed: 100)) // a very fast two minutes
        history.append(makeRecord(minutes: 1, reviewed: 1))
        XCTAssertNil(history.usualPace, "only two runs count")
        history.append(makeRecord(minutes: 3, reviewed: 9))
        XCTAssertEqual(history.usualPace, 3, "3 minutes counts: paces 2, 3 and 3")
    }

    func testTheUsualPaceIsTheMedianOfTheLastTenCountedRuns() {
        var history = RunHistory()
        // Old runs at a slow pace of 1, followed by ten at 2 to 3: the old ones fall out of the window.
        for _ in 0..<5 { history.append(makeRecord(minutes: 10, reviewed: 10)) }
        for pace in [20, 24, 22, 30, 26, 28, 21, 23, 25, 27] { history.append(makeRecord(minutes: 10, reviewed: pace)) }
        // sorted: 20 21 22 23 24 25 26 27 28 30 -> median (24 + 25) / 2 = 24.5 over 10 minutes
        XCTAssertEqual(history.usualPace ?? 0, 2.45, accuracy: 0.0001)

        var odd = RunHistory()
        for reviewed in [10, 30, 20] { odd.append(makeRecord(minutes: 10, reviewed: reviewed)) }
        XCTAssertEqual(odd.usualPace, 2, "the middle one, not the mean")
    }

    func testTheSplitByDeckAddsUpRecentRuns() {
        let a = Deck.ID(), b = Deck.ID(), c = Deck.ID()
        var history = RunHistory()
        history.append(makeRecord(byDeck: [a: 5, b: 3]))
        history.append(makeRecord(byDeck: [a: 4, c: 6]))
        XCTAssertEqual(history.deckSplit(), [a: 9, b: 3, c: 6])
        XCTAssertEqual(history.deckSplit(recent: 1), [a: 4, c: 6])
        XCTAssertEqual(history.last?.deckCounts, [a: 4, c: 6], "and the split of just the last run")
    }

    // MARK: From a run

    func testARunThatEndedEarlyIsSavedWithTheTimeItReallyRan() {
        let a = Deck.ID()
        var run = ReviewRun(startedAt: start, minutes: 10)
        run.record(.good, cardID: Card.ID(), deckID: a, at: start.addingTimeInterval(30))
        run.end(at: start.addingTimeInterval(252)) // 4:12
        XCTAssertEqual(RunRecord(run: run, deckIDs: [a]).minutes, 4)

        var quick = ReviewRun(startedAt: start, minutes: 10)
        quick.record(.good, cardID: Card.ID(), deckID: a, at: start.addingTimeInterval(5))
        quick.end(at: start.addingTimeInterval(20))
        XCTAssertEqual(RunRecord(run: quick, deckIDs: [a]).minutes, 1, "at least one minute")
    }

    func testARunThatRanOutIsSavedWithItsFullLength() {
        let a = Deck.ID()
        var run = ReviewRun(startedAt: start, minutes: 5)
        run.record(.good, cardID: Card.ID(), deckID: a, at: start.addingTimeInterval(100))
        run.record(.easy, cardID: Card.ID(), deckID: a, at: start.addingTimeInterval(320)) // the grade after 0:00
        XCTAssertTrue(run.isEnded)
        XCTAssertEqual(RunRecord(run: run, deckIDs: [a]).minutes, 5)
    }

    func testTheRecordCarriesTheCountsDecksAndGrades() {
        let a = Deck.ID(), b = Deck.ID()
        var run = ReviewRun(startedAt: start, minutes: 10)
        for (grade, deck) in [(ReviewGrade.again, a), (.good, a), (.good, b), (.easy, b), (.hard, a)] {
            run.record(grade, cardID: Card.ID(), deckID: deck, at: start.addingTimeInterval(60))
        }
        run.end(at: start.addingTimeInterval(600))
        let saved = RunRecord(run: run, deckIDs: [a, b])
        XCTAssertEqual(saved.reviewed, 5)
        XCTAssertEqual(saved.minutes, 10)
        XCTAssertEqual(saved.deckIDs, [a, b])
        XCTAssertEqual(saved.deckCounts, [a: 3, b: 2])
        XCTAssertEqual(saved.grades, RunRecord.Grades(again: 1, hard: 1, good: 2, easy: 1))
        XCTAssertEqual(saved.startedAt, start)
        XCTAssertEqual(saved.pace, 0.5, accuracy: 0.0001)
    }
}

@MainActor
final class RunHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testRecordingPublishesAndSaves() {
        let store = RunHistoryStore(storage: RunHistoryStorage(directory: directory))
        XCTAssertTrue(store.history.isEmpty)
        store.record(makeRecord(reviewed: 12))
        XCTAssertEqual(store.history.last?.reviewed, 12)
        XCTAssertEqual(RunHistoryStorage(directory: directory).load().last?.reviewed, 12, "and it's on disk")
        XCTAssertEqual(RunHistoryStore(storage: RunHistoryStorage(directory: directory)).history.last?.reviewed, 12, "after a relaunch")
    }

    func testRefreshPicksUpAnotherProcessesWrite() throws {
        let store = RunHistoryStore(storage: RunHistoryStorage(directory: directory))
        try RunHistoryStorage(directory: directory).append(makeRecord(reviewed: 3))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: RunHistoryStorage(directory: directory).fileURL.path
        )
        store.refresh()
        XCTAssertEqual(store.history.last?.reviewed, 3)
    }

    func testASaveThatFailsDoesNotLoseTheRunForThisSession() throws {
        // A file where the folder should be: nothing can be written.
        let blocker = directory.deletingLastPathComponent().appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = RunHistoryStore(storage: RunHistoryStorage(directory: blocker.appendingPathComponent("nested")))
        store.record(makeRecord(reviewed: 4))
        XCTAssertEqual(store.history.last?.reviewed, 4)
    }
}

@MainActor
final class SprintRecordingTests: XCTestCase {
    private var decks: [Deck] = []
    private var clockNow = Date(timeIntervalSince1970: 1_800_000_000)
    private var saved: [RunRecord] = []

    override func setUp() {
        decks = [
            Deck(name: "a", cards: (1...3).map { Card(front: "a\($0)", back: "back") }),
            Deck(name: "b", cards: (1...2).map { Card(front: "b\($0)", back: "back") }),
        ]
        saved = []
    }

    private func makeModel(minutes: Int = 10, history: ReviewResults.History = .empty) -> ReviewSprintModel {
        var setup = ReviewSetup(minutes: minutes)
        setup.ticked = Set(decks.map(\.id))
        return ReviewSprintModel.start(
            setup: setup, decks: { [unowned self] in decks }, playback: { [:] }, grader: { _, _, _, _ in },
            clock: { [unowned self] in clockNow }, history: history, onFinished: { [unowned self] in if let record = $0 { saved.append(record) } }
        )
    }

    private func grade(_ model: ReviewSprintModel, _ grade: ReviewGrade, after seconds: TimeInterval = 30) {
        clockNow = clockNow.addingTimeInterval(seconds)
        model.handle(.space)
        model.handle(.grade(grade))
    }

    func testAFinishedSprintIsRecordedOnce() {
        let model = makeModel()
        grade(model, .good)
        grade(model, .again)
        XCTAssertTrue(saved.isEmpty, "not until it is over")
        clockNow = clockNow.addingTimeInterval(120)
        model.handle(.escape)
        model.confirmEnd()
        model.confirmEnd()

        XCTAssertEqual(saved.count, 1)
        let run = saved[0]
        XCTAssertEqual(run.reviewed, 2)
        XCTAssertEqual(run.minutes, 3, "ended after 3 minutes")
        XCTAssertEqual(run.deckIDs.count, 2)
        XCTAssertEqual(run.grades.good, 1)
        XCTAssertEqual(run.grades.again, 1)
    }

    func testRunningOutOrFinishingTheQueueIsRecordedToo() {
        let model = makeModel(minutes: 1)
        clockNow = clockNow.addingTimeInterval(61)
        model.tick()
        model.handle(.space)
        model.handle(.grade(.good))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].minutes, 1)

        saved = []
        let all = makeModel()
        for _ in 0..<5 { grade(all, .good, after: 10) }
        XCTAssertEqual(all.phase, .finished(.queueFinished))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].reviewed, 5)
    }

    func testASprintWithNothingGradedIsNotKept() {
        let model = makeModel()
        model.handle(.escape)
        model.confirmEnd()
        XCTAssertTrue(saved.isEmpty)
    }

    func testTheResultsComparedWithWhatCameBefore() {
        let before = ReviewResults.History(usualPace: 2.1, lastCount: 19, lastSeconds: 600)
        let model = makeModel(history: before)
        grade(model, .good)
        model.confirmEnd()
        let results = model.results(study: nil)
        XCTAssertEqual(results.usualPaceText, "2.1 a minute")
        XCTAssertEqual(results.lastSprintText, "19 cards in 10:00", "the sprint before this one, not this one")
    }

    func testTheSetupSheetEstimateComesFromTheHistory() {
        var history = RunHistory()
        for reviewed in [20, 22, 21] { history.append(makeRecord(minutes: 10, reviewed: reviewed)) }
        let big = Deck(name: "big", cards: (1...60).map { Card(front: "c\($0)", back: "b") })
        var setup = ReviewSetup(startingWith: big.id, minutes: 10)
        setup.cards = .everythingShuffled
        let summary = ReviewSetupSummary(
            decks: [big], playback: [:], setup: setup, now: Date(), usualPace: history.resultsHistory.usualPace
        )
        XCTAssertEqual(summary.estimateLine, "About 21 cards at your usual 2.1 a minute, across 1 deck.")
    }
}

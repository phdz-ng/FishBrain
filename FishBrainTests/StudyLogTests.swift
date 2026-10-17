import XCTest

/// The streak and the daily goal (FLAS-39).
final class StudyLogTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday
        c.minimumDaysInFirstWeek = 4
        return c
    }()

    /// 2026-10-08 is a Thursday.
    private func date(_ day: Int, month: Int = 10, hour: Int = 12, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func study(_ log: inout StudyLog, cards: Int, on day: Date, goal: Int = 20, offset: Int = 0) {
        for _ in 0..<cards { log.record(cardID: UUID(), at: day, goal: goal, calendar: calendar) }
    }

    // MARK: Counting

    func testACardCountsOnceADayHoweverOftenItComesRound() {
        var log = StudyLog()
        let card = UUID()
        XCTAssertTrue(log.record(cardID: card, at: date(8, hour: 9), goal: 20, calendar: calendar))
        XCTAssertFalse(log.record(cardID: card, at: date(8, hour: 15), goal: 20, calendar: calendar), "same card, same day")
        XCTAssertEqual(log.count(on: date(8), calendar: calendar), 1)
        XCTAssertTrue(log.record(cardID: card, at: date(9), goal: 20, calendar: calendar), "counts again tomorrow")
        XCTAssertEqual(log.count(on: date(9), calendar: calendar), 1)
        XCTAssertEqual(log.count(on: date(8), calendar: calendar), 1, "yesterday keeps its count")
    }

    func testOnlyTodayKeepsCardIDs() {
        var log = StudyLog()
        study(&log, cards: 5, on: date(7))
        study(&log, cards: 3, on: date(8))
        XCTAssertEqual(log.todayCards.count, 3, "yesterday's ids are dropped, so the file stays small")
        XCTAssertEqual(log.days.count, 2)
    }

    func testDaysAreKeyedByTheCalendarDay() {
        XCTAssertEqual(StudyLog.key(for: date(8), calendar: calendar), "2026-10-08")
        XCTAssertEqual(StudyLog.key(for: date(8, hour: 23, minute: 59), calendar: calendar), "2026-10-08")
        XCTAssertEqual(StudyLog.key(for: date(9, hour: 0, minute: 1), calendar: calendar), "2026-10-09")
    }

    func testAMonthOfOldDaysIsKeptButNotForever() {
        var log = StudyLog()
        let start = date(1, month: 1)
        for offset in 0..<(StudyLog.daysKept + 30) {
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            log.record(cardID: UUID(), at: day, goal: 1, calendar: calendar)
        }
        XCTAssertLessThanOrEqual(log.days.count, StudyLog.daysKept + 1)
    }

    // MARK: Streak

    func testNothingStudiedMeansNoStreak() {
        let summary = StudyLog().summary(at: date(8), goal: 20, calendar: calendar)
        XCTAssertEqual(summary.streak, 0)
        XCTAssertEqual(summary.streakText, "Start a streak")
        XCTAssertEqual(summary.count, 0)
    }

    func testTheStreakCountsConsecutiveDaysWithTheGoalMet() {
        var log = StudyLog()
        for day in 5...8 { study(&log, cards: 20, on: date(day)) }
        XCTAssertEqual(log.streak(at: date(8), goal: 20, calendar: calendar), 4)
    }

    func testTodayStillOpenDoesNotBreakAStreakEndingYesterday() {
        var log = StudyLog()
        for day in 5...7 { study(&log, cards: 20, on: date(day)) }
        study(&log, cards: 4, on: date(8)) // today so far
        XCTAssertEqual(log.streak(at: date(8), goal: 20, calendar: calendar), 3)
        study(&log, cards: 16, on: date(8))
        XCTAssertEqual(log.streak(at: date(8), goal: 20, calendar: calendar), 4, "today joins it once met")
    }

    func testAMissedDayStartsOver() {
        var log = StudyLog()
        for day in 3...5 { study(&log, cards: 20, on: date(day)) }
        // 6th and 7th missed
        XCTAssertEqual(log.streak(at: date(8), goal: 20, calendar: calendar), 0)
        study(&log, cards: 20, on: date(8))
        XCTAssertEqual(log.streak(at: date(8), goal: 20, calendar: calendar), 1)
    }

    func testAnAlmostMetDayDoesNotCount() {
        var log = StudyLog()
        study(&log, cards: 19, on: date(7))
        XCTAssertEqual(log.streak(at: date(8), goal: 20, calendar: calendar), 0)
    }

    func testAGoalReachedStaysReachedWhenTheGoalIsRaisedLater() {
        var log = StudyLog()
        for day in 5...7 { study(&log, cards: 20, on: date(day), goal: 20) }
        XCTAssertEqual(log.streak(at: date(8), goal: 50, calendar: calendar), 3, "past days were met at the goal of the time")
    }

    func testLoweringTheGoalCountsTodayAtOnce() {
        var log = StudyLog()
        study(&log, cards: 12, on: date(8), goal: 30)
        XCTAssertEqual(log.streak(at: date(8), goal: 30, calendar: calendar), 0)
        XCTAssertEqual(log.streak(at: date(8), goal: 10, calendar: calendar), 1)
    }

    func testTheStreakSurvivesAMonthBoundary() {
        var log = StudyLog()
        study(&log, cards: 20, on: date(30, month: 9))
        study(&log, cards: 20, on: date(1, month: 10))
        study(&log, cards: 20, on: date(2, month: 10))
        XCTAssertEqual(log.streak(at: date(2, month: 10), goal: 20, calendar: calendar), 3)
    }

    func testTheClockMovingBackDoesNotCountTheSameCardsTwiceInADay() {
        var log = StudyLog()
        let card = UUID()
        log.record(cardID: card, at: date(8, hour: 20), goal: 20, calendar: calendar)
        XCTAssertFalse(log.record(cardID: card, at: date(8, hour: 8), goal: 20, calendar: calendar))
    }

    // MARK: The week

    func testTheWeekHasSevenDotsStartingOnTheFirstWeekday() {
        var log = StudyLog()
        study(&log, cards: 20, on: date(5)) // Monday
        study(&log, cards: 20, on: date(6))
        study(&log, cards: 20, on: date(7))
        study(&log, cards: 7, on: date(8))  // Thursday: today
        let week = log.summary(at: date(8), goal: 20, calendar: calendar).week
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.map(\.state), [.met, .met, .met, .open, .upcoming, .upcoming, .upcoming])
        XCTAssertEqual(week.map(\.isToday), [false, false, false, true, false, false, false])
    }

    func testAMissedDayIsOpenAndTodayFillsOnceTheGoalIsMet() {
        var log = StudyLog()
        study(&log, cards: 20, on: date(7))
        study(&log, cards: 20, on: date(8))
        let week = log.summary(at: date(8), goal: 20, calendar: calendar).week
        XCTAssertEqual(week[0].state, .open, "Monday: nothing studied")
        XCTAssertEqual(week[3].state, .met)
        XCTAssertTrue(week[3].isToday)
    }

    func testTheWeekFollowsTheCalendarsFirstWeekday() {
        var sunday = calendar
        sunday.firstWeekday = 1
        sunday.minimumDaysInFirstWeek = 1
        let week = StudyLog().summary(at: date(8), goal: 20, calendar: sunday).week
        XCTAssertEqual(week.map(\.isToday), [false, false, false, false, true, false, false], "Thursday is the fifth day of a Sunday-first week")
    }

    // MARK: Text

    func testTheWordsAreSpokenAndWrittenAsSpecified() {
        let summary = StudySummary(count: 18, goal: 30, streak: 12, week: [])
        XCTAssertEqual(summary.streakText, "12 days")
        XCTAssertEqual(summary.progressText, "18 / 30 today")
        XCTAssertEqual(summary.openLine, "18 of 30 today · 12-day streak")
        XCTAssertEqual(summary.accessibilityText, "12-day streak, 18 of 30 cards today")
        XCTAssertFalse(summary.goalMetToday)
    }

    func testOneDayAndNoStreak() {
        XCTAssertEqual(StudySummary(count: 3, goal: 20, streak: 1, week: []).streakText, "1 day")
        XCTAssertEqual(StudySummary(count: 3, goal: 20, streak: 1, week: []).openLine, "3 of 20 today · 1-day streak")
        let none = StudySummary(count: 3, goal: 20, streak: 0, week: [])
        XCTAssertEqual(none.openLine, "3 of 20 today", "no streak phrase until there is one")
        XCTAssertEqual(none.accessibilityText, "No streak yet, 3 of 20 cards today")
    }

    func testTheGoalMetFlag() {
        XCTAssertTrue(StudySummary(count: 20, goal: 20, streak: 1, week: []).goalMetToday)
        XCTAssertTrue(StudySummary(count: 25, goal: 20, streak: 1, week: []).goalMetToday)
    }
}

final class StudyStorageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAMissingOrUnreadableFileMeansNothingStudied() throws {
        let storage = StudyStorage(directory: directory)
        XCTAssertEqual(storage.load(), StudyLog())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: storage.fileURL)
        XCTAssertEqual(storage.load(), StudyLog())
    }

    func testTheLogRoundTrips() throws {
        let storage = StudyStorage(directory: directory)
        var log = StudyLog()
        log.record(cardID: UUID(), at: Date(timeIntervalSince1970: 1_800_000_000), goal: 1)
        try storage.save(log)
        XCTAssertEqual(storage.load(), log)
    }

    func testTwoWritersDoNotLoseEachOthersCards() async throws {
        let storage = StudyStorage(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask { try? storage.modify { $0.record(cardID: UUID(), at: now, goal: 100) } }
            }
        }
        XCTAssertEqual(storage.load().count(on: now), 40, "every card was counted")
    }
}

/// Flips from the app, the notch and the widget all count, through one place.
final class StudyRecordingTests: XCTestCase {
    private var directory: URL!
    private var deck: Deck!
    private let scheduler = CardScheduler()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        deck = Deck(name: "Spanish", color: .green, cards: (1...10).map { Card(front: "f\($0)", back: "b\($0)") })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var playback: PlaybackStorage { PlaybackStorage(directory: directory) }
    private var study: StudyStorage { StudyStorage(directory: directory) }

    func testFlippingToTheAnswerCountsTheCard() throws {
        try PlaybackActions.flip(deck, in: playback, at: now)
        XCTAssertEqual(study.load().count(on: now), 1)
    }

    func testFlippingBackDoesNotCountAgain() throws {
        try PlaybackActions.flip(deck, in: playback, at: now)
        try PlaybackActions.flip(deck, in: playback, at: now) // back to the front
        try PlaybackActions.flip(deck, in: playback, at: now) // answer again: same card, same day
        XCTAssertEqual(study.load().count(on: now), 1)
    }

    func testEachNewCardCounts() throws {
        for slot in 0..<3 {
            let at = now.addingTimeInterval(Double(slot) * scheduler.interval)
            try PlaybackActions.flip(deck, in: playback, at: at)
        }
        XCTAssertEqual(study.load().count(on: now), 3)
    }

    func testSkippingAloneCountsNothing() throws {
        try PlaybackActions.skip(deck, in: playback, at: now)
        XCTAssertEqual(study.load().count(on: now), 0)
    }

    func testAWidgetFlipCountsToo() throws {
        try DeckStorage(directory: directory).save([deck])
        XCTAssertTrue(try PlaybackActions.perform(.flip, deckID: deck.id.uuidString, decks: DeckStorage(directory: directory), playback: playback, at: now))
        XCTAssertEqual(study.load().count(on: now), 1, "the widget writes the same file the app reads")
    }

    func testTheGoalInTheSettingsFileDecidesWhetherTheDayIsMet() throws {
        try SettingsStorage(directory: directory).save(AppSettings(dailyGoal: 2))
        for slot in 0..<2 {
            try PlaybackActions.flip(deck, in: playback, at: now.addingTimeInterval(Double(slot) * scheduler.interval))
        }
        XCTAssertEqual(study.load().streak(at: now, goal: 2), 1)
        XCTAssertTrue(study.load().days.values.allSatisfy(\.met), "met at the goal of the time")
    }

    func testAFlipOnAnEmptyDeckCountsNothingAndDoesNotFail() throws {
        try PlaybackActions.flip(Deck(name: "Empty", color: .green, cards: []), in: playback, at: now)
        XCTAssertEqual(study.load().count(on: now), 0)
    }
}

final class DailyGoalSettingTests: XCTestCase {
    func testDefaultsAndChoices() {
        XCTAssertEqual(AppSettings().dailyGoal, 20)
        XCTAssertEqual(AppSettings.dailyGoalChoices, [10, 20, 30, 50])
    }

    func testAGoalBelowOneIsRaisedToOne() {
        XCTAssertEqual(AppSettings(dailyGoal: 0).dailyGoal, 1)
        XCTAssertEqual(AppSettings(dailyGoal: -5).dailyGoal, 1)
    }

    func testTheGoalIsSavedAndAnOlderFileGetsTwenty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SettingsStorage(directory: directory)
        try storage.save(AppSettings(dailyGoal: 30))
        XCTAssertEqual(storage.load().dailyGoal, 30)
        try Data(#"{"accent":"teal"}"#.utf8).write(to: storage.fileURL)
        XCTAssertEqual(storage.load().dailyGoal, 20)
    }

    func testThePickerOffersTheChoicesAndAnOddSavedValue() {
        XCTAssertEqual(DailyGoal.choices(including: 20), [10, 20, 30, 50])
        XCTAssertEqual(DailyGoal.choices(including: 25), [10, 20, 25, 30, 50])
    }

    @MainActor
    func testTheStoreSavesTheGoalAndRefusesZero() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SettingsStorage(directory: directory)
        let store = SettingsStore(storage: storage, onSaved: {})
        store.dailyGoal = 50
        XCTAssertEqual(storage.load().dailyGoal, 50)
        store.dailyGoal = 0
        XCTAssertEqual(store.dailyGoal, 50, "a goal of zero would make every day a success")
    }
}

@MainActor
final class StudyNotchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController(now: Date, goal: Int = 3) throws -> (NotchController, StudyStore, PlaybackStore, SettingsStore) {
        let deck = Deck(name: "Spanish", color: .green, cards: (1...10).map { Card(front: "f\($0)", back: "b\($0)") })
        try DeckStorage(directory: root).save([deck])
        let deckStore = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        settings.dailyGoal = goal
        let studyStore = StudyStore(storage: StudyStorage(directory: root))
        let screen = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876),
            safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, displayID: 1, isBuiltIn: true
        )
        let controller = NotchController(
            placementProvider: { NotchGeometry.placement(for: screen) },
            showsPanel: false, installsMonitors: false, watchDirectory: root,
            clock: { now },
            deckStore: { deckStore }, playbackStore: { playback }, settingsStore: { settings },
            studyStore: { studyStore }
        )
        addTeardownBlock { controller.stop() }
        controller.start()
        return (controller, studyStore, playback, settings)
    }

    func testFlippingACardUpdatesTheSummaryTheNotchShows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (controller, _, _, _) = try makeController(now: now)
        XCTAssertEqual(controller.model.study?.count, 0)
        controller.model.onFlip()
        XCTAssertEqual(controller.model.study?.count, 1)
        XCTAssertEqual(controller.model.study?.goal, 3)
        XCTAssertEqual(controller.model.study?.openLine, "1 of 3 today")
    }

    func testReachingTheGoalStartsTheStreak() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (controller, _, _, _) = try makeController(now: now)
        for _ in 0..<3 {
            controller.model.onFlip()
            controller.model.onSkip()
        }
        XCTAssertEqual(controller.model.study?.count, 3)
        XCTAssertEqual(controller.model.study?.goalMetToday, true)
        XCTAssertEqual(controller.model.study?.streak, 1)
    }

    func testChangingTheGoalUpdatesTheSummaryAtOnce() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (controller, _, _, settings) = try makeController(now: now)
        controller.model.onFlip()
        settings.dailyGoal = 50
        controller.refreshContent()
        XCTAssertEqual(controller.model.study?.goal, 50)
    }

    func testWithoutAStudyStoreThereIsNoSummary() throws {
        let deckStore = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(5), onSaved: {})
        let playback = PlaybackStore(storage: PlaybackStorage(directory: root), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: root), onSaved: {})
        let controller = NotchController(
            placementProvider: { nil }, showsPanel: false, installsMonitors: false, watchDirectory: root,
            deckStore: { deckStore }, playbackStore: { playback }, settingsStore: { settings }
        )
        addTeardownBlock { controller.stop() }
        controller.start()
        XCTAssertNil(controller.model.study)
    }

    func testTheStreakPillIsOnOfferAndStaysUnderTheModestWidth() {
        XCTAssertTrue(PillStyle.available.contains(.streak))
        XCTAssertLessThanOrEqual(NotchGeometry.drawnWidth(forPositionText: "12/40", style: .streak), 300)
        XCTAssertGreaterThan(NotchGeometry.drawnWidth(forPositionText: "12/40", style: .streak), NotchGeometry.drawnWidth(forPositionText: "12/40", style: .fish))
    }
}

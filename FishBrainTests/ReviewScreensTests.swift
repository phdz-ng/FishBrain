import AppKit
import SwiftUI
import XCTest

/// The Review sprint's screens (FLAS-59): the setup sheet's maths, the running screen's keys and clock,
/// and the results, from a fixed run.
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600

private func makeDeck(_ name: String, _ count: Int, color: DeckColor = .accent) -> Deck {
    Deck(name: name, color: color, cards: (1...count).map { Card(front: "\(name)\($0)", back: "\(name) back \($0)") })
}

private func reviewState(due: TimeInterval, reps: Int = 2) -> ReviewState {
    ReviewState(due: now.addingTimeInterval(due), interval: 86_400, ease: 2.5, reps: reps, lapses: 0, lastReviewed: now.addingTimeInterval(-86_400))
}

private func playbackState(_ deck: Deck, _ reviews: [Int: TimeInterval]) -> PlaybackState {
    var state = PlaybackState()
    for (position, due) in reviews { state.reviews[deck.cards[position].id.uuidString] = reviewState(due: due) }
    return state
}

// MARK: Setup

final class ReviewSetupTests: XCTestCase {
    private let a = makeDeck("a", 5), b = makeDeck("b", 4), c = makeDeck("c", 3)

    /// a: 2 due, 1 graded for later, 2 new. b: 1 due, 3 new. c: all graded for later (caught up).
    private var playback: [Deck.ID: PlaybackState] {
        [
            a.id: playbackState(a, [0: -hour, 1: -2 * hour, 2: 5 * 24 * hour]),
            b.id: playbackState(b, [0: -hour]),
            c.id: playbackState(c, [0: 24 * hour, 1: 24 * hour, 2: 24 * hour]),
        ]
    }

    private func summary(_ ids: [Deck], cards: ReviewQueue.Options.Cards = .dueThenNew, minutes: Int = 10, pace: Double? = nil) -> ReviewSetupSummary {
        var setup = ReviewSetup(minutes: minutes)
        setup.ticked = Set(ids.map(\.id))
        setup.cards = cards
        return ReviewSetupSummary(decks: [a, b, c], playback: playback, setup: setup, now: now, usualPace: pace)
    }

    func testEachDeckHasDueNewAndTotalCounts() {
        XCTAssertEqual(ReviewSetupSummary.counts(for: a, state: playback[a.id], now: now), ReviewDeckCounts(due: 2, new: 2, total: 5))
        XCTAssertEqual(ReviewSetupSummary.counts(for: b, state: playback[b.id], now: now), ReviewDeckCounts(due: 1, new: 3, total: 4))
        XCTAssertEqual(ReviewSetupSummary.counts(for: c, state: playback[c.id], now: now), ReviewDeckCounts(due: 0, new: 0, total: 3))
        XCTAssertEqual(ReviewSetupSummary.counts(for: a, state: nil, now: now), ReviewDeckCounts(due: 0, new: 5, total: 5))
    }

    func testRowsSayHowManyAreDueOrCaughtUp() {
        XCTAssertEqual(ReviewDeckCounts(due: 14, new: 0, total: 20).dueText, "14 due")
        XCTAssertEqual(ReviewDeckCounts(due: 0, new: 3, total: 20).dueText, "Caught up")
    }

    func testTheSummaryLineAddsUpTheTickedDecks() {
        let s = summary([a, b, c])
        XCTAssertEqual(s.summaryLine, "3 decks ticked · 3 due · 5 new")
        XCTAssertEqual(summary([b]).summaryLine, "1 deck ticked · 1 due · 3 new")
        XCTAssertEqual(summary([]).summaryLine, "0 decks ticked · 0 due · 0 new")
    }

    func testEachChoiceOfCardsShowsItsOwnCount() {
        let s = summary([a, b])
        XCTAssertEqual(s.countText(for: .dueThenNew), "3 due, then 5 new")
        XCTAssertEqual(s.countText(for: .dueOnly), "3 cards")
        XCTAssertEqual(s.countText(for: .everythingShuffled), "9 cards")
        XCTAssertEqual(summary([c]).countText(for: .dueThenNew), "0 due")
        XCTAssertEqual(summary([b]).countText(for: .dueOnly), "1 card")
    }

    func testTheQueueCountFollowsTheChoice() {
        XCTAssertEqual(summary([a, b], cards: .dueThenNew).queueCount, 8)
        XCTAssertEqual(summary([a, b], cards: .dueOnly).queueCount, 3)
        XCTAssertEqual(summary([a, b], cards: .everythingShuffled).queueCount, 9)
    }

    func testTheCountsMatchTheQueueThatWouldBeBuilt() {
        for cards in ReviewQueue.Options.Cards.allCases {
            var setup = ReviewSetup(minutes: 10)
            setup.ticked = [a.id, b.id, c.id]
            setup.cards = cards
            let summary = ReviewSetupSummary(decks: [a, b, c], playback: playback, setup: setup, now: now)
            let queue = ReviewQueue.build(deckIDs: setup.ticked, in: [a, b, c], playback: playback, options: setup.options, now: now)
            XCTAssertEqual(summary.queueCount, queue.count, "\(cards)")
        }
    }

    func testStartTitleShowsTheLength() {
        XCTAssertEqual(summary([a], minutes: 10).startTitle, "Start 10:00")
        XCTAssertEqual(summary([a], minutes: 25).startTitle, "Start 25:00")
        XCTAssertEqual(summary([a], minutes: 7).startTitle, "Start 7:00")
    }

    func testStartIsOffWithNothingTickedAndSaysWhy() {
        XCTAssertEqual(summary([]).startDisabledReason, "Tick at least one deck.")
        XCTAssertNil(summary([a]).startDisabledReason)
    }

    func testStartIsOffWhenTheQueueWouldBeEmpty() {
        XCTAssertEqual(summary([c], cards: .dueOnly).startDisabledReason, "Nothing is due in the ticked decks.")
        XCTAssertNil(summary([c], cards: .everythingShuffled).startDisabledReason, "caught up, but there are cards to go through")
        let empty = Deck(name: "Empty")
        var setup = ReviewSetup(startingWith: empty.id)
        setup.cards = .dueThenNew
        let s = ReviewSetupSummary(decks: [empty], playback: [:], setup: setup, now: now)
        XCTAssertEqual(s.startDisabledReason, "The ticked decks have no cards.")
    }

    func testTheEstimateIsHiddenUntilThereIsHistory() {
        XCTAssertNil(summary([a, b]).estimateLine)
        XCTAssertNil(summary([a, b], pace: 0).estimateLine)
        XCTAssertNil(summary([], pace: 2).estimateLine, "nothing ticked")
    }

    func testTheEstimateUsesTheUsualPaceAndTheLength() {
        let big = makeDeck("big", 60)
        var setup = ReviewSetup(startingWith: big.id, minutes: 10)
        setup.cards = .everythingShuffled
        let s = ReviewSetupSummary(decks: [big], playback: [:], setup: setup, now: now, usualPace: 2.1)
        XCTAssertEqual(s.estimateLine, "About 21 cards at your usual 2.1 a minute, across 1 deck.")
    }

    func testTheEstimateSaysAllFitWhenThereAreFewerCardsThanTheTime() {
        var setup = ReviewSetup(startingWith: b.id, minutes: 15)
        setup.cards = .dueOnly
        let s = ReviewSetupSummary(decks: [a, b], playback: playback, setup: setup, now: now, usualPace: 2.0)
        XCTAssertEqual(s.estimateLine, "All 1 card should fit at your usual 2.0 a minute, across 1 deck.")
    }

    func testTheShortcutChips() {
        var setup = ReviewSetup(startingWith: a.id)
        XCTAssertEqual(setup.ticked, [a.id], "the current deck starts ticked")
        setup.tickEverythingDue(decks: [a, b, c], playback: playback, now: now)
        XCTAssertEqual(setup.ticked, [a.id, b.id], "c is caught up")
        setup.tickOnly(c.id)
        XCTAssertEqual(setup.ticked, [c.id])
        setup.toggle(a.id)
        XCTAssertEqual(setup.ticked, [a.id, c.id])
        setup.toggle(c.id)
        setup.clear()
        XCTAssertTrue(setup.ticked.isEmpty)
    }

    func testTheLengthStaysBetweenOneAndSixtyAndDefaultsWhenNothingIsOverridden() {
        var setup = ReviewSetup()
        XCTAssertEqual(setup.minutes, 10)
        XCTAssertEqual(setup.cards, .dueThenNew)
        XCTAssertFalse(setup.shuffleBetweenDecks, "off by default")
        setup.setMinutes(0)
        XCTAssertEqual(setup.minutes, 1)
        setup.setMinutes(500)
        XCTAssertEqual(setup.minutes, 60)
        XCTAssertEqual(ReviewSetup(minutes: 15).minutes, 15)
    }
}

@MainActor
final class ReviewMinutesSettingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testTheLastLengthIsRemembered() {
        let first = SettingsStore(storage: SettingsStorage(directory: directory), onSaved: {})
        XCTAssertEqual(first.reviewMinutes, 10)
        first.reviewMinutes = 25
        let second = SettingsStore(storage: SettingsStorage(directory: directory), onSaved: {})
        XCTAssertEqual(second.reviewMinutes, 25)
    }

    func testAnOldSettingsFileWithoutItStillLoads() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.reviewMinutes, 10)
        let wild = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"reviewMinutes": 900}"#.utf8))
        XCTAssertEqual(wild.reviewMinutes, 60)
    }
}

// MARK: Results

final class ReviewResultsTests: XCTestCase {
    private let spanish = makeDeck("Spanish", 5), verbs = makeDeck("Verbs", 4), cells = makeDeck("Cells", 3)
    private func t(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    /// 6 grades in 10 minutes over three decks: two Again (one card twice), one Hard, two Good, one Easy.
    private func fixedRun() -> ReviewRun {
        var run = ReviewRun(startedAt: now, minutes: 10)
        run.record(.again, cardID: spanish.cards[0].id, deckID: spanish.id, at: t(40))
        run.record(.good, cardID: verbs.cards[0].id, deckID: verbs.id, at: t(90))
        run.record(.again, cardID: cells.cards[1].id, deckID: cells.id, at: t(150))
        run.record(.hard, cardID: spanish.cards[1].id, deckID: spanish.id, at: t(210))
        run.record(.good, cardID: spanish.cards[0].id, deckID: spanish.id, at: t(300)) // came back, and was graded again
        run.record(.easy, cardID: verbs.cards[2].id, deckID: verbs.id, at: t(420))
        run.end(at: t(600))
        return run
    }

    private func results(study: StudySummary? = nil, history: ReviewResults.History = .empty, ending: ReviewResults.Ending = .timeUp) -> ReviewResults {
        ReviewResults(run: fixedRun(), ending: ending, decks: [spanish, verbs, cells], study: study, history: history)
    }

    func testTheBigCountPaceAndHeadline() {
        let r = results()
        XCTAssertEqual(r.count, 6)
        XCTAssertEqual(r.paceLine, "cards in 10:00 · 0.6 a minute")
        XCTAssertEqual(r.headline, "Time's up · 3 decks")
        XCTAssertEqual(results(ending: .ended).headline, "Sprint ended · 3 decks")
        XCTAssertEqual(results(ending: .queueFinished).headline, "All done · 3 decks")
    }

    func testAnEndedEarlyRunSaysHowLongItRan() {
        var run = ReviewRun(startedAt: now, minutes: 10)
        run.record(.good, cardID: spanish.cards[0].id, deckID: spanish.id, at: t(100))
        run.end(at: t(252))
        let r = ReviewResults(run: run, ending: .ended, decks: [spanish])
        XCTAssertEqual(r.paceLine, "card in 4:12 · 0.2 a minute")
        XCTAssertEqual(r.headline, "Sprint ended · 1 deck")
    }

    func testRememberedIsGoodOrEasy() {
        let r = results()
        XCTAssertEqual(r.remembered, 3)
        XCTAssertEqual(r.rememberedText, "3 of 6")
    }

    func testTheGradeBarAddsUpToTheWhole() {
        let fractions = results().gradeFractions
        XCTAssertEqual(fractions.map(\.grade), [.again, .hard, .good, .easy])
        XCTAssertEqual(fractions.map(\.fraction).reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(fractions[0].fraction, 2.0 / 6, accuracy: 0.0001)
        XCTAssertEqual(fractions[2].fraction, 2.0 / 6, accuracy: 0.0001)
        XCTAssertEqual(results().gradeCounts, [.again: 2, .hard: 1, .good: 2, .easy: 1])
    }

    func testByDeckIsBusiestFirstWithBarsRelativeToIt() {
        let rows = results().byDeck
        XCTAssertEqual(rows.map(\.name), ["Spanish", "Verbs", "Cells"])
        XCTAssertEqual(rows.map(\.count), [3, 2, 1])
        XCTAssertEqual(rows[0].fraction, 1)
        XCTAssertEqual(rows[1].fraction, 2.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(results().deckCount, 3)
    }

    func testCameUpAgainListsEachForgottenCardOnceWithItsDeck() {
        let again = results().again
        XCTAssertEqual(again.map(\.front), ["Spanish1", "Cells2"])
        XCTAssertEqual(again.map(\.deckName), ["Spanish", "Cells"])
    }

    func testTheFollowUpRoundHoldsExactlyTheAgainCards() {
        let r = results()
        XCTAssertEqual(r.followUpTitle, "Review the 2 missed · 1 min")
        let queue = r.followUpQueue()
        XCTAssertEqual(queue.entries, [
            ReviewQueue.Entry(cardID: spanish.cards[0].id, deckID: spanish.id),
            ReviewQueue.Entry(cardID: cells.cards[1].id, deckID: cells.id),
        ])
        XCTAssertEqual(ReviewResults.followUpMinutes, 1)
    }

    func testNoMissedCardsMeansNoFollowUp() {
        var run = ReviewRun(startedAt: now, minutes: 5)
        run.record(.good, cardID: spanish.cards[0].id, deckID: spanish.id, at: t(30))
        let r = ReviewResults(run: run, ending: .ended, decks: [spanish])
        XCTAssertNil(r.followUpTitle)
        XCTAssertTrue(r.followUpQueue().isEmpty)
        XCTAssertTrue(r.again.isEmpty)
    }

    func testAMissedCardThatWasDeletedIsLeftOutOfTheListButNotTheMath() {
        var cut = spanish
        cut.cards.removeFirst()
        let r = ReviewResults(run: fixedRun(), ending: .timeUp, decks: [cut, verbs, cells])
        XCTAssertEqual(r.again.map(\.front), ["Cells2"])
        XCTAssertEqual(r.count, 6)
    }

    func testGoalAndStreakLine() {
        func line(count: Int, goal: Int, streak: Int) -> String {
            ReviewResults.goalLine(StudySummary(count: count, goal: goal, streak: streak, week: []))
        }
        XCTAssertEqual(line(count: 41, goal: 30, streak: 13), "41 of 30 today, goal reached · 13-day streak")
        XCTAssertEqual(line(count: 18, goal: 30, streak: 12), "18 of 30 today · 12-day streak")
        XCTAssertEqual(line(count: 3, goal: 30, streak: 0), "3 of 30 today")
        XCTAssertNil(results().goalLine, "no study summary, no line")
        XCTAssertEqual(results(study: StudySummary(count: 18, goal: 30, streak: 12, week: [])).goalLine, "18 of 30 today · 12-day streak")
    }

    func testPastSprintChipsAppearOnlyWithHistory() {
        XCTAssertNil(results().usualPaceText)
        XCTAssertNil(results().lastSprintText)
        let r = results(history: ReviewResults.History(usualPace: 2.1, lastCount: 19, lastSeconds: 600))
        XCTAssertEqual(r.usualPaceText, "2.1 a minute")
        XCTAssertEqual(r.lastSprintText, "19 cards in 10:00")
    }

    func testClockFormatting() {
        XCTAssertEqual(ReviewResults.clock(600), "10:00")
        XCTAssertEqual(ReviewResults.clock(252), "4:12")
        XCTAssertEqual(ReviewResults.clock(45.4), "0:45")
        XCTAssertEqual(ReviewResults.clock(-3), "0:00")
    }
}

// MARK: Running

@MainActor
final class ReviewSprintModelTests: XCTestCase {
    private var decks: [Deck] = []
    private var states: [Deck.ID: PlaybackState] = [:]
    private var clockNow = now
    private var graded: [(ReviewGrade, Card.ID)] = []
    private var announcements: [String] = []
    private var directory: URL!

    private var a: Deck { decks[0] }
    private var b: Deck { decks[1] }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        decks = [makeDeck("a", 3), makeDeck("b", 2)]
        // b1 is the most overdue, then a1; a2, a3 and b2 are new.
        states = [
            decks[0].id: playbackState(decks[0], [0: -hour]),
            decks[1].id: playbackState(decks[1], [0: -2 * hour]),
        ]
        clockNow = now
        graded = []
        announcements = []
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func makeModel(minutes: Int = 10, setup: ReviewSetup? = nil, useStorage: PlaybackStorage? = nil) -> ReviewSprintModel {
        var setup = setup ?? ReviewSetup(minutes: minutes)
        if setup.ticked.isEmpty { setup.ticked = Set(decks.map(\.id)) }
        setup.minutes = minutes
        let model = ReviewSprintModel.start(
            setup: setup,
            decks: { [unowned self] in decks },
            playback: { [unowned self] in states },
            grader: { [unowned self] grade, id, deck, date in
                graded.append((grade, id))
                if let useStorage { _ = try? PlaybackActions.grade(grade, cardID: id, in: deck, storage: useStorage, at: date) }
            },
            clock: { [unowned self] in clockNow }
        )
        model.onAnnouncement = { [unowned self] in announcements.append($0) }
        return model
    }

    private func advance(_ seconds: TimeInterval, _ model: ReviewSprintModel) {
        clockNow = clockNow.addingTimeInterval(seconds)
        model.tick()
    }

    // The queue here is: b1, a1 (due, most overdue first), then a2, a3, b2 (new).

    func testStartsOnTheMostOverdueCardAndCountsWhatIsDue() throws {
        let model = makeModel()
        XCTAssertEqual(model.current?.card.front, "b1")
        XCTAssertEqual(model.queue.count, 5)
        XCTAssertEqual(model.dueLeft, 2)
        XCTAssertEqual(model.reviewed, 0)
        XCTAssertEqual(model.remaining, 600)
        XCTAssertEqual(model.deckCount, 2)
        XCTAssertTrue(model.showsDeckName)
        XCTAssertEqual(model.title, "2 decks · Review sprint")
        XCTAssertFalse(model.isFlipped)
    }

    func testOneDeckShowsItsNameInTheTitleAndNotOnTheCard() {
        var setup = ReviewSetup(startingWith: a.id)
        setup.minutes = 10
        let model = makeModel(setup: setup)
        XCTAssertEqual(model.title, "a · Review sprint")
        XCTAssertFalse(model.showsDeckName)
    }

    func testNumberKeysGradeOnlyAfterTheCardIsTurnedOver() {
        let model = makeModel()
        XCTAssertFalse(model.handle(.grade(.good)), "the answer hasn't been seen")
        XCTAssertEqual(model.reviewed, 0)

        XCTAssertTrue(model.handle(.space))
        XCTAssertTrue(model.isFlipped)
        XCTAssertTrue(model.handle(.grade(.hard)))
        XCTAssertEqual(model.reviewed, 1)
        XCTAssertEqual(graded.map(\.0), [.hard])
        XCTAssertEqual(model.current?.card.front, "a1", "moved on")
        XCTAssertFalse(model.isFlipped, "to a front")
    }

    func testEachNumberKeyIsItsGrade() {
        for grade in ReviewGrade.allCases {
            let model = makeModel()
            model.handle(.space)
            model.handle(.grade(grade))
            XCTAssertEqual(graded.last?.0, grade)
        }
        XCTAssertEqual(ReviewGrade.allCases.map { String($0.shortcutKey) }, ["1", "2", "3", "4"])
    }

    func testSpaceFlipsAndThenGradesGood() {
        let model = makeModel()
        model.handle(.space)
        XCTAssertTrue(model.isFlipped)
        XCTAssertTrue(graded.isEmpty)
        model.handle(.space)
        XCTAssertEqual(graded.map(\.0), [.good])
        XCTAssertEqual(graded.first?.1, decks[1].cards[0].id)
        XCTAssertEqual(model.reviewed, 1)
    }

    func testPauseStopsTheClockBlocksGradingAndResumes() {
        let model = makeModel()
        advance(60, model)
        XCTAssertEqual(model.remaining, 540)
        model.handle(.pause)
        XCTAssertTrue(model.isPaused)
        advance(300, model)
        XCTAssertEqual(model.remaining, 540, "paused for five minutes: nothing used")
        XCTAssertFalse(model.handle(.space), "the card is blurred")
        model.flip()
        XCTAssertFalse(model.isFlipped)
        model.handle(.pause)
        XCTAssertFalse(model.isPaused)
        advance(30, model)
        XCTAssertEqual(model.remaining, 510)
    }

    func testEscAsksBeforeEnding() {
        let model = makeModel()
        model.handle(.space)
        model.handle(.grade(.good))
        model.handle(.escape)
        XCTAssertTrue(model.isConfirmingEnd)
        XCTAssertTrue(model.isRunning, "nothing ends until it is confirmed")
        model.isConfirmingEnd = false
        XCTAssertEqual(model.reviewed, 1)

        model.handle(.escape)
        model.confirmEnd()
        XCTAssertEqual(model.phase, .finished(.ended))
        XCTAssertFalse(model.isConfirmingEnd)
        XCTAssertFalse(model.handle(.space), "no keys once it is over")
        XCTAssertEqual(model.results(study: nil).count, 1)
    }

    func testACardGradedAgainComesBackAndStaysCountedAsDue() {
        let model = makeModel()
        model.handle(.space); model.handle(.grade(.good)) // b1 gone; a1 is next
        XCTAssertEqual(model.dueLeft, 1)
        model.handle(.space)
        model.handle(.grade(.again)) // a1 goes back
        XCTAssertEqual(model.dueLeft, 1, "it still has to come up")
        XCTAssertEqual(model.queue.count, 4)
        XCTAssertEqual(model.queue.entries.last?.cardID, decks[0].cards[0].id, "back after the others that are left")
        // Go through the rest.
        for _ in 0..<3 { model.handle(.space); model.handle(.grade(.good)) }
        XCTAssertEqual(model.current?.card.front, "a1")
        model.handle(.space); model.handle(.grade(.good))
        XCTAssertEqual(model.phase, .finished(.queueFinished))
        XCTAssertEqual(model.reviewed, 6)
        XCTAssertEqual(model.results(study: nil).againEntries.count, 1)
    }

    func testTheCardOnScreenAtZeroCanStillBeGradedAndThenTheRunEnds() {
        let model = makeModel(minutes: 1)
        advance(61, model)
        XCTAssertTrue(model.isTimeUp)
        XCTAssertTrue(model.isRunning, "0:00 alone doesn't end it")
        XCTAssertEqual(model.remaining, 0)
        model.handle(.pause)
        XCTAssertFalse(model.isPaused, "no pausing at 0:00")

        model.handle(.space)
        model.handle(.grade(.good))
        XCTAssertEqual(model.phase, .finished(.timeUp))
        XCTAssertEqual(model.reviewed, 1)
        XCTAssertEqual(model.results(study: nil).headline, "Time's up · 2 decks")
    }

    func testTheTimerIsAnnouncedAtOneMinuteThirtySecondsAndZero() {
        let model = makeModel(minutes: 2)
        advance(30, model)
        XCTAssertTrue(announcements.isEmpty)
        advance(31, model) // 59 s left
        XCTAssertEqual(announcements, ["1 minute left"])
        advance(10, model)
        advance(20, model) // 29 s left
        XCTAssertEqual(announcements, ["1 minute left", "30 seconds left"])
        advance(40, model)
        XCTAssertEqual(announcements, ["1 minute left", "30 seconds left", "Time's up"])
        advance(5, model)
        XCTAssertEqual(announcements.count, 3, "once each")
    }

    func testAnnouncementThresholds() {
        XCTAssertEqual(ReviewSprintModel.announcement(from: 61, to: 59.5), "1 minute left")
        XCTAssertEqual(ReviewSprintModel.announcement(from: 60, to: 59), nil, "60 exactly was already reached")
        XCTAssertEqual(ReviewSprintModel.announcement(from: 31, to: 30), "30 seconds left")
        XCTAssertEqual(ReviewSprintModel.announcement(from: 0.5, to: 0), "Time's up")
        XCTAssertNil(ReviewSprintModel.announcement(from: 100, to: 90))
        XCTAssertNil(ReviewSprintModel.announcement(from: 0, to: 0))
    }

    func testTheSpokenTime() {
        XCTAssertEqual(ReviewSprintView.spokenTime(462), "7 minutes 42 seconds left")
        XCTAssertEqual(ReviewSprintView.spokenTime(60), "1 minute left")
        XCTAssertEqual(ReviewSprintView.spokenTime(1), "1 second left")
        XCTAssertEqual(ReviewSprintView.spokenTime(0), "0 seconds left")
    }

    func testTheQueueDoesNotChangeWhenDecksAreEditedAndADeletedCardIsSkipped() {
        let model = makeModel()
        let before = model.queue.entries.map(\.cardID)
        // Edit, rename and reorder: the queue is the same.
        decks[0].cards.append(Card(front: "late", back: "late"))
        decks[1].name = "renamed"
        decks.reverse()
        model.decksDidChange()
        XCTAssertEqual(model.queue.entries.map(\.cardID), before)

        // The card on screen is deleted: it is passed over.
        let gone = model.current!.card.id
        for i in decks.indices { decks[i].cards.removeAll { $0.id == gone } }
        model.decksDidChange()
        XCTAssertEqual(model.current?.card.front, "a1")
        XCTAssertEqual(model.queue.count, 4)
        XCTAssertEqual(model.queue.entries.map(\.cardID), Array(before.dropFirst()))
    }

    func testTheRotationTheWidgetAndNotchFollowIsNotMoved() throws {
        let storage = PlaybackStorage(directory: directory)
        var state = states[a.id] ?? PlaybackState()
        state.skipOffset = 7
        state.flip = PlaybackState.Flip(position: 7, cardID: a.cards[2].id)
        try storage.save([a.id: state, b.id: states[b.id] ?? PlaybackState()])
        let model = makeModel(useStorage: storage)

        for _ in 0..<3 { model.handle(.space); model.handle(.grade(.good)) }

        let after = try XCTUnwrap(storage.load()[a.id])
        XCTAssertEqual(after.skipOffset, 7)
        XCTAssertEqual(after.flip, state.flip)
        XCTAssertNotNil(storage.load()[b.id]?.review(for: b.cards[0].id), "the grade itself was saved")
        XCTAssertEqual(StudyStorage(directory: directory).load().count(on: now), 3, "and counted toward the goal")
    }

    func testTheFollowUpRoundIsOneMinuteOfExactlyTheMissedCards() {
        let model = makeModel()
        model.handle(.space); model.handle(.grade(.again))  // b1
        model.handle(.space); model.handle(.grade(.good))   // a1
        model.handle(.space); model.handle(.grade(.again))  // a2
        model.handle(.escape); model.confirmEnd()

        let results = model.results(study: nil)
        let followUp = ReviewSprintModel.followUp(
            from: results, setup: model.setup,
            decks: { [unowned self] in decks }, playback: { [unowned self] in states },
            grader: { _, _, _, _ in }, clock: { [unowned self] in clockNow }
        )
        XCTAssertEqual(followUp.queue.entries.map(\.cardID), [decks[1].cards[0].id, decks[0].cards[1].id])
        XCTAssertEqual(followUp.run.minutes, 1)
        XCTAssertEqual(followUp.dueLeft, 2)
        XCTAssertTrue(followUp.isRunning)
    }

    func testTheFishFollowsTheClockAndStepsWithReduceMotion() {
        var run = ReviewRun(startedAt: now, minutes: 10)
        XCTAssertEqual(ReviewSprintModel.trackProgress(run: run, at: now.addingTimeInterval(20), reduceMotion: false), 20.0 / 600, accuracy: 0.0001)
        XCTAssertEqual(ReviewSprintModel.trackProgress(run: run, at: now.addingTimeInterval(14), reduceMotion: true), 0)
        XCTAssertEqual(ReviewSprintModel.trackProgress(run: run, at: now.addingTimeInterval(20), reduceMotion: true), 15.0 / 600, accuracy: 0.0001)
        run.pause(at: now.addingTimeInterval(100))
        XCTAssertEqual(
            ReviewSprintModel.trackProgress(run: run, at: now.addingTimeInterval(5_000), reduceMotion: false), 100.0 / 600, accuracy: 0.0001,
            "paused: the fish stays where it is"
        )
    }

    func testTheGradeButtonsHaveTheNumbersOnThemAndGapsForTheCardOnScreen() {
        let model = makeModel()
        XCTAssertEqual(model.intervals, ReviewScheduler.intervals(from: states[b.id]?.review(for: b.cards[0].id)))
        XCTAssertFalse(model.canGrade, "until it is turned over")
        model.flip()
        XCTAssertTrue(model.canGrade)
    }
}

// MARK: Screens

@MainActor
final class ReviewScreensLayoutTests: XCTestCase {
    private func render<V: View>(_ view: V, size: CGSize) throws {
        let framed = view.frame(width: size.width, height: size.height).preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 1
        XCTAssertNotNil(renderer.cgImage)
    }

    func testTheSetupSheetLaysOut() throws {
        let sheet = ReviewSetupSheet(initialDeckID: PreviewData.decks[0].id, minutes: 10, onStart: { _ in }, onCancel: {})
            .environmentObject(PreviewData.store())
            .environmentObject(PreviewData.playback())
            .environment(\.accentChoice, .default)
        try render(sheet, size: CGSize(width: ReviewSetupSheet.width, height: 560))
        let size = NSHostingView(rootView: sheet).fittingSize
        XCTAssertEqual(size.width, ReviewSetupSheet.width, accuracy: 1)
        XCTAssertLessThan(size.width, MainWindowView.minimumSize.width, "fits the window at its minimum width")
        XCTAssertLessThan(size.height, 680)
    }

    func testTheRunningAndResultsScreensLayOutAtTheMinimumWindowSize() throws {
        let decks = PreviewData.decks
        let model = ReviewSprintModel.start(
            setup: { var s = ReviewSetup(startingWith: decks[0].id); s.ticked.insert(decks[1].id); return s }(),
            decks: { decks }, playback: { [:] }, grader: { _, _, _, _ in }
        )
        let screen = ReviewSprintView(model: model, onSameMix: {}, onFollowUp: { _ in }, onDone: {})
            .environmentObject(PreviewData.study())
            .environmentObject(PreviewData.settings())
            .environment(\.accentChoice, .default)
        try render(screen, size: MainWindowView.minimumSize)

        model.handle(.space)
        model.handle(.grade(.again))
        model.handle(.escape)
        model.confirmEnd()
        XCTAssertEqual(model.phase, .finished(.ended))
        try render(screen, size: MainWindowView.minimumSize)
    }
}

import XCTest

/// The Review sprint's core (FLAS-58): the queue, the run's clock and grading a named card.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600

private func makeDeck(_ name: String, _ count: Int) -> Deck {
    Deck(name: name, cards: (1...count).map { Card(front: "\(name)\($0)", back: "back") })
}

private func review(due: TimeInterval, reps: Int = 2) -> ReviewState {
    ReviewState(due: now.addingTimeInterval(due), interval: 86_400, ease: 2.5, reps: reps, lapses: 0, lastReviewed: now.addingTimeInterval(-86_400))
}

private func state(_ deck: Deck, _ reviews: [Int: TimeInterval]) -> PlaybackState {
    var state = PlaybackState()
    for (position, due) in reviews { state.reviews[deck.cards[position].id.uuidString] = review(due: due) }
    return state
}

private func fronts(_ queue: ReviewQueue, in decks: [Deck]) -> [String] {
    let cards = Dictionary(uniqueKeysWithValues: decks.flatMap(\.cards).map { ($0.id, $0.front) })
    return queue.entries.map { cards[$0.cardID] ?? "?" }
}

final class ReviewQueueTests: XCTestCase {
    private let a = makeDeck("a", 4)
    private let b = makeDeck("b", 3)

    /// a2 and a4 are due 3 h ago, b1 5 h ago, b3 is graded but not due for a day; a1, a3 and b2 are new.
    private var playback: [Deck.ID: PlaybackState] {
        [
            a.id: state(a, [1: -3 * hour, 3: -3 * hour]),
            b.id: state(b, [0: -5 * hour, 2: 24 * hour]),
        ]
    }

    func testDueCardsComeMostOverdueFirstThenNewCardsInDeckOrder() {
        let queue = ReviewQueue.build(decks: [a, b], playback: playback, now: now)
        // b1 is the most overdue; a2 and a4 tie and keep card order; new cards follow in deck order.
        // b3 is graded but not due, so it isn't in a due-then-new sprint at all.
        XCTAssertEqual(fronts(queue, in: [a, b]), ["b1", "a2", "a4", "a1", "a3", "b2"])
    }

    func testTiesAcrossDecksKeepDeckOrderThenCardOrder() {
        let tied = [a.id: state(a, [2: -hour, 0: -hour]), b.id: state(b, [0: -hour])]
        let queue = ReviewQueue.build(decks: [a, b], playback: tied, options: .init(cards: .dueOnly), now: now)
        XCTAssertEqual(fronts(queue, in: [a, b]), ["a1", "a3", "b1"])
        let swapped = ReviewQueue.build(decks: [b, a], playback: tied, options: .init(cards: .dueOnly), now: now)
        XCTAssertEqual(fronts(swapped, in: [a, b]), ["b1", "a1", "a3"])
    }

    func testDueOnlyLeavesOutNewCards() {
        let queue = ReviewQueue.build(decks: [a, b], playback: playback, options: .init(cards: .dueOnly), now: now)
        XCTAssertEqual(fronts(queue, in: [a, b]), ["b1", "a2", "a4"])
    }

    func testACardDueExactlyNowIsDue() {
        let exact = [a.id: state(a, [0: 0])]
        let queue = ReviewQueue.build(decks: [a], playback: exact, options: .init(cards: .dueOnly), now: now)
        XCTAssertEqual(fronts(queue, in: [a]), ["a1"])
    }

    func testADeckNobodyHasGradedIsAllNew() {
        let queue = ReviewQueue.build(decks: [a, b], playback: [:], now: now)
        XCTAssertEqual(fronts(queue, in: [a, b]), ["a1", "a2", "a3", "a4", "b1", "b2", "b3"])
        XCTAssertTrue(ReviewQueue.build(decks: [a, b], playback: [:], options: .init(cards: .dueOnly), now: now).isEmpty)
    }

    func testEverythingShuffledHasEveryCardOnceDueOrNot() {
        var rng = SplitMix64(state: 11)
        let queue = ReviewQueue.build(decks: [a, b], playback: playback, options: .init(cards: .everythingShuffled), now: now, using: &rng)
        XCTAssertEqual(queue.count, 7)
        XCTAssertEqual(Set(queue.entries.map(\.cardID)), Set((a.cards + b.cards).map(\.id)))
        XCTAssertNotEqual(fronts(queue, in: [a, b]), ["a1", "a2", "a3", "a4", "b1", "b2", "b3"], "and not in deck order")
    }

    func testDecksTakeTurnsWhenShuffledBetweenDecks() {
        let big = makeDeck("big", 6), small = makeDeck("small", 2), mid = makeDeck("mid", 3)
        let all = [big, small, mid]
        let due = Dictionary(uniqueKeysWithValues: all.map { deck in
            (deck.id, state(deck, Dictionary(uniqueKeysWithValues: deck.cards.indices.map { ($0, -Double($0 + 1) * hour) })))
        })
        for seed in 0..<25 {
            var rng = SplitMix64(state: UInt64(seed))
            let queue = ReviewQueue.build(
                decks: all, playback: due, options: .init(cards: .dueOnly, shuffleBetweenDecks: true), now: now, using: &rng
            )
            XCTAssertEqual(queue.count, 11)
            let decks = queue.entries.map(\.deckID)
            // Round 1 and 2 have a card from each deck; in round 3 the small deck has run out, and
            // from round 4 only the big deck has cards left.
            XCTAssertEqual(Set(decks[0..<3]).count, 3, "seed \(seed): everyone gets a turn first")
            XCTAssertEqual(Set(decks[3..<6]).count, 3, "seed \(seed): and again")
            XCTAssertEqual(Set(decks[6..<8]), [big.id, mid.id], "seed \(seed): the small deck is out")
            XCTAssertEqual(Set(decks[8...]), [big.id], "seed \(seed): only the big deck is left")
            // Each deck's own order (most overdue first) is kept.
            for deck in all {
                let mine = queue.entries.filter { $0.deckID == deck.id }.map(\.cardID)
                XCTAssertEqual(mine, deck.cards.reversed().map(\.id), "seed \(seed): \(deck.name)")
            }
        }
    }

    func testTurnsAreStillDueFirstThenNew() {
        var rng = SplitMix64(state: 3)
        let queue = ReviewQueue.build(
            decks: [a, b], playback: playback, options: .init(shuffleBetweenDecks: true), now: now, using: &rng
        )
        let names = fronts(queue, in: [a, b])
        XCTAssertEqual(Set(names.prefix(3)), ["b1", "a2", "a4"], "the due cards first")
        XCTAssertEqual(Set(names.suffix(3)), ["a1", "a3", "b2"], "then the new ones")
        XCTAssertEqual(queue.count, 6)
    }

    func testAnyDeckWithNoCardsOrListedTwiceIsHarmless() {
        let empty = Deck(name: "Empty")
        let queue = ReviewQueue.build(decks: [a, empty, a], playback: [:], now: now)
        XCTAssertEqual(queue.count, 4)
        XCTAssertTrue(ReviewQueue.build(decks: [empty], playback: [:], now: now).isEmpty)
        XCTAssertNil(ReviewQueue().current)
    }

    func testBuildingFromAChosenSetOfDeckIDsUsesTheLibraryOrder() {
        var rng = SystemRandomNumberGenerator()
        let c = makeDeck("c", 2)
        let queue = ReviewQueue.build(deckIDs: [c.id, a.id, UUID()], in: [a, b, c], playback: [:], now: now, using: &rng)
        XCTAssertEqual(fronts(queue, in: [a, b, c]), ["a1", "a2", "a3", "a4", "c1", "c2"], "b isn't ticked; the stray id is ignored")
    }

    // MARK: Again

    private func makeQueue(_ count: Int) -> ReviewQueue {
        ReviewQueue.build(decks: [makeDeck("c", count)], playback: [:], now: now)
    }

    func testACardGradedAgainComesBackAFewCardsLater() {
        var queue = makeQueue(8)
        let first = queue.entries[0]
        XCTAssertEqual(queue.grade(.again), first)
        XCTAssertEqual(queue.count, 8, "it stays in the queue")
        XCTAssertEqual(queue.entries[ReviewQueue.againOffset], first, "four others show before it does")
    }

    func testAgainAgainPutsItBackAgainAfterEachFurtherAgain() {
        var queue = makeQueue(10)
        let card = queue.entries[0]
        queue.grade(.again)
        for _ in 0..<ReviewQueue.againOffset { queue.grade(.good) }
        XCTAssertEqual(queue.current, card, "back after four others")
        queue.grade(.again)
        XCTAssertEqual(queue.entries[ReviewQueue.againOffset], card, "and again")
        for _ in 0..<ReviewQueue.againOffset { queue.grade(.good) }
        XCTAssertEqual(queue.current, card)
        queue.grade(.good)
        XCTAssertFalse(queue.entries.contains(card), "Good lets it go")
    }

    func testHardGoodAndEasyLeaveTheQueue() {
        for grade in [ReviewGrade.hard, .good, .easy] {
            var queue = makeQueue(5)
            let card = queue.entries[0]
            queue.grade(grade)
            XCTAssertEqual(queue.count, 4, "\(grade)")
            XCTAssertFalse(queue.entries.contains(card))
        }
    }

    func testAgainWithFewCardsLeftGoesToTheEnd() {
        var queue = makeQueue(3)
        let first = queue.entries[0]
        queue.grade(.again)
        XCTAssertEqual(queue.entries.last, first)
        var single = makeQueue(1)
        single.grade(.again)
        XCTAssertEqual(single.count, 1, "the last card comes straight back")
        var empty = ReviewQueue()
        XCTAssertNil(empty.grade(.good))
    }

    // MARK: Stable under edits

    func testTheQueueIsNotAffectedByEditingOrMovingDecksAfterItIsBuilt() throws {
        var decks = [a, b]
        let queue = ReviewQueue.build(decks: decks, playback: playback, now: now)
        let snapshot = queue.entries

        decks[0].cards.remove(at: 1)
        decks[0].cards.append(Card(front: "new", back: "new"))
        decks[1].name = "renamed"
        decks.reverse()
        decks.removeAll { $0.id == b.id }

        XCTAssertEqual(queue.entries, snapshot, "it holds ids and never looks at the decks again")
        // Round trip, as a sprint that is saved would be.
        let data = try JSONEncoder().encode(queue)
        XCTAssertEqual(try JSONDecoder().decode(ReviewQueue.self, from: data), queue)
    }
}

final class ReviewRunTests: XCTestCase {
    private let deck = Deck.ID()
    private let card = Card.ID()
    private func makeRun(minutes: Int = 10) -> ReviewRun { ReviewRun(startedAt: now, minutes: minutes) }
    private func t(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    func testTheLengthIsOneToSixtyMinutes() {
        XCTAssertEqual(ReviewRun.lengths, [5, 10, 15, 25])
        XCTAssertEqual(makeRun(minutes: 0).minutes, 1)
        XCTAssertEqual(makeRun(minutes: 90).minutes, 60)
        XCTAssertEqual(makeRun(minutes: 25).minutes, 25)
        XCTAssertEqual(makeRun(minutes: 7).duration, 420)
    }

    func testTimeLeftComesFromTheClock() {
        let run = makeRun()
        XCTAssertEqual(run.remaining(at: now), 600)
        XCTAssertEqual(run.remaining(at: t(125)), 475)
        XCTAssertEqual(run.progress(at: t(300)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(run.remaining(at: t(5_000)), 0, "never negative")
        XCTAssertEqual(run.remaining(at: t(-30)), 600, "a clock set back doesn't add time")
    }

    func testPausingStopsTheClockAndResumingContinues() {
        var run = makeRun()
        run.pause(at: t(120))
        XCTAssertTrue(run.isPaused)
        XCTAssertEqual(run.remaining(at: t(120)), 480)
        XCTAssertEqual(run.remaining(at: t(1_000)), 480, "paused for 15 minutes: nothing used")
        run.resume(at: t(1_000))
        XCTAssertFalse(run.isPaused)
        XCTAssertEqual(run.remaining(at: t(1_060)), 420)
        XCTAssertEqual(run.remaining(at: t(1_480)), 0, "10 minutes of running plus the 880 s pause")
        XCTAssertTrue(run.isTimeUp(at: t(1_480)))
    }

    func testPausingTwiceOrResumingARunningRunDoesNothing() {
        var run = makeRun()
        run.resume(at: t(10))
        XCTAssertEqual(run.pausedTotal, 0)
        run.pause(at: t(100))
        run.pause(at: t(300))
        run.resume(at: t(400))
        XCTAssertEqual(run.pausedTotal, 300, "the first pause counted, the second didn't restart it")
    }

    func testSleepCannotStretchARun() {
        // The Mac slept from minute 3 to an hour in: nothing ticked, but the clock says it's over.
        var run = makeRun()
        XCTAssertEqual(run.remaining(at: t(180)), 420)
        XCTAssertTrue(run.isTimeUp(at: t(3_600)))
        XCTAssertEqual(run.remaining(at: t(3_600)), 0)
        // A pause that began before the sleep stays a pause: the time asleep wasn't running time either.
        run.pause(at: t(180))
        XCTAssertEqual(run.remaining(at: t(3_600)), 420)
    }

    func testTheCardOnScreenCanBeGradedAtZeroAndThenTheRunEnds() {
        var run = makeRun(minutes: 1)
        XCTAssertTrue(run.record(.good, cardID: card, deckID: deck, at: t(30)))
        XCTAssertFalse(run.isEnded, "time is left")

        XCTAssertTrue(run.isTimeUp(at: t(60)))
        XCTAssertFalse(run.isEnded, "0:00 alone doesn't end it: the card on screen can still be graded")
        XCTAssertTrue(run.record(.hard, cardID: Card.ID(), deckID: deck, at: t(75)))
        XCTAssertTrue(run.isEnded)
        XCTAssertEqual(run.reviewed, 2)
        XCTAssertFalse(run.record(.good, cardID: Card.ID(), deckID: deck, at: t(80)), "and nothing after that")
        XCTAssertEqual(run.reviewed, 2)
        XCTAssertEqual(run.elapsed(at: t(500)), 60, "the clock stopped at its length")
    }

    func testEndingEarlyStopsTheClock() {
        var run = makeRun()
        run.end(at: t(200))
        XCTAssertTrue(run.isEnded)
        XCTAssertEqual(run.elapsed(at: t(900)), 200)
        XCTAssertEqual(run.remaining(at: t(900)), 400)
        run.pause(at: t(250))
        XCTAssertFalse(run.isPaused)
        XCTAssertFalse(run.record(.good, cardID: card, deckID: deck, at: t(260)))
    }

    func testPausingAtZeroIsIgnoredSoTheLastGradeStillEndsIt() {
        var run = makeRun(minutes: 1)
        run.pause(at: t(61))
        XCTAssertFalse(run.isPaused)
        XCTAssertTrue(run.record(.good, cardID: card, deckID: deck, at: t(62)))
        XCTAssertTrue(run.isEnded)
    }

    func testGradingWhilePausedResumesFirst() {
        var run = makeRun()
        run.pause(at: t(100))
        run.record(.good, cardID: card, deckID: deck, at: t(400))
        XCTAssertFalse(run.isPaused)
        XCTAssertEqual(run.pausedTotal, 300)
        XCTAssertEqual(run.remaining(at: t(400)), 500)
    }

    func testSummaryCountsGradesDecksAndAgainCards() {
        let d1 = Deck.ID(), d2 = Deck.ID()
        let c1 = Card.ID(), c2 = Card.ID(), c3 = Card.ID()
        var run = makeRun(minutes: 10)
        run.record(.again, cardID: c1, deckID: d1, at: t(30))
        run.record(.good, cardID: c2, deckID: d1, at: t(60))
        run.record(.again, cardID: c3, deckID: d2, at: t(90))
        run.record(.again, cardID: c1, deckID: d1, at: t(120))
        run.record(.easy, cardID: c1, deckID: d1, at: t(150))
        run.record(.hard, cardID: c2, deckID: d2, at: t(180))
        run.pause(at: t(200))
        run.resume(at: t(260)) // a minute away

        let summary = run.summary(at: t(360)) // 5 minutes of running time
        XCTAssertEqual(summary.count, 6)
        XCTAssertEqual(summary.elapsed, 300)
        XCTAssertEqual(summary.pace, 6.0 / 5.0, accuracy: 0.0001)
        XCTAssertEqual(summary.gradeCounts, [.again: 3, .hard: 1, .good: 1, .easy: 1])
        XCTAssertEqual(summary.deckCounts, [d1: 4, d2: 2])
        XCTAssertEqual(summary.againCards, [c1, c3], "each once, in the order they were first forgotten")
    }

    func testTheSummaryOfAnEndedRunMeasuresItsOwnLength() {
        var run = makeRun(minutes: 5)
        run.record(.good, cardID: card, deckID: deck, at: t(60))
        run.record(.good, cardID: Card.ID(), deckID: deck, at: t(120))
        run.end(at: t(240))
        let summary = run.summary
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.elapsed, 240)
        XCTAssertEqual(summary.pace, 0.5, accuracy: 0.0001)
        XCTAssertEqual(ReviewRun(startedAt: now).summary.pace, 0, "nothing graded, nothing elapsed")
    }

    func testARunSurvivesBeingSavedAndRead() throws {
        var run = makeRun(minutes: 15)
        run.record(.again, cardID: card, deckID: deck, at: t(40))
        run.pause(at: t(50))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        XCTAssertEqual(try decoder.decode(ReviewRun.self, from: encoder.encode(run)), run)
    }
}

final class GradeByCardTests: XCTestCase {
    private var directory: URL!
    private var storage: PlaybackStorage!
    private let deck = makeDeck("d", 20)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = PlaybackStorage(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testItSchedulesTheNamedCardAndLeavesTheRotationAlone() throws {
        let shown = deck.cards[3], graded = deck.cards[11]
        var state = PlaybackState(skipOffset: 5)
        state.flip = PlaybackState.Flip(position: 5, cardID: shown.id)
        try storage.save([deck.id: state])

        let result = try PlaybackActions.grade(.good, cardID: graded.id, in: deck, storage: storage, at: now)

        let after = try XCTUnwrap(result[deck.id])
        XCTAssertEqual(after.skipOffset, 5, "the widget and notch rotation didn't move")
        XCTAssertEqual(after.flip, state.flip, "and the flip is as it was")
        let review = try XCTUnwrap(after.review(for: graded.id))
        XCTAssertEqual(review.due, now.addingTimeInterval(ReviewScheduler.day))
        XCTAssertEqual(review.reps, 1)
        XCTAssertNil(after.review(for: shown.id), "other cards are untouched")
        XCTAssertEqual(storage.load()[deck.id], after, "and it was saved")
    }

    func testItNeedsNoFlipAndCountsTowardTodaysGoal() throws {
        let card = deck.cards[0]
        try PlaybackActions.grade(.easy, cardID: card.id, in: deck, storage: storage, at: now)
        XCTAssertEqual(StudyStorage(directory: directory).load().count(on: now), 1)
        try PlaybackActions.grade(.again, cardID: card.id, in: deck, storage: storage, at: now.addingTimeInterval(60))
        XCTAssertEqual(StudyStorage(directory: directory).load().count(on: now), 1, "once a day per card")
    }

    func testGradingAgainAfterAgainBuildsOnTheLastReview() throws {
        let card = deck.cards[2]
        try PlaybackActions.grade(.good, cardID: card.id, in: deck, storage: storage, at: now)
        let result = try PlaybackActions.grade(.again, cardID: card.id, in: deck, storage: storage, at: now.addingTimeInterval(86_400))
        let review = try XCTUnwrap(result[deck.id]?.review(for: card.id))
        XCTAssertEqual(review.lapses, 1, "it had graduated with Good, so forgetting it is a lapse")
        XCTAssertEqual(review.reps, 0)
        XCTAssertEqual(review.interval, ReviewScheduler.minute)
    }

    func testAnUnknownCardIsIgnoredAndDeletedCardsReviewsArePruned() throws {
        let gone = Card(front: "gone", back: "gone")
        var state = PlaybackState()
        state.reviews[gone.id.uuidString] = review(due: hour)
        try storage.save([deck.id: state])

        try PlaybackActions.grade(.good, cardID: UUID(), in: deck, storage: storage, at: now)
        XCTAssertNotNil(storage.load()[deck.id]?.review(for: gone.id), "nothing was graded, so nothing was touched")
        XCTAssertEqual(StudyStorage(directory: directory).load().count(on: now), 0)

        try PlaybackActions.grade(.good, cardID: deck.cards[0].id, in: deck, storage: storage, at: now)
        XCTAssertNil(storage.load()[deck.id]?.review(for: gone.id), "a deleted card's schedule is dropped, as grade does")
    }

    func testItIsSafeAgainstAConcurrentAppOrWidgetWrite() throws {
        let skips = 20
        let other = PlaybackStorage(directory: directory) // another process's handle on the same file
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "writers", attributes: .concurrent)
        var failures = 0
        let lock = NSLock()
        for i in 0..<(2 * skips) {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    if i.isMultiple(of: 2) {
                        try PlaybackActions.grade(.good, cardID: self.deck.cards[i / 2].id, in: self.deck, storage: self.storage, at: now)
                    } else {
                        try PlaybackActions.skip(self.deck, in: other, at: now)
                    }
                } catch {
                    lock.lock(); failures += 1; lock.unlock()
                }
            }
        }
        group.wait()

        XCTAssertEqual(failures, 0)
        let result = try XCTUnwrap(storage.load()[deck.id])
        XCTAssertEqual(result.skipOffset, skips, "every skip from the other writer is still there")
        XCTAssertEqual(result.reviews.count, skips, "and every grade")
    }
}

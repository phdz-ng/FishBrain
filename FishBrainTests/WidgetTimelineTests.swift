import XCTest

final class WidgetTimelineTests: XCTestCase {
    private let scheduler = CardScheduler()
    private let interval = CardScheduler.defaultInterval
    private let deck = Deck(name: "D", cards: (0..<10).map { Card(front: "f\($0)", back: "b\($0)") })

    private func slotStart(_ n: Int, plus seconds: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: Double(n) * interval + seconds)
    }

    private func timeline(
        at now: Date,
        deck: Deck? = nil,
        playback: [Deck.ID: PlaybackState] = [:],
        horizon: TimeInterval = 3600
    ) -> EntryTimeline {
        let d = deck ?? self.deck
        return FishBrainEntry.timeline(decks: [d], playback: playback, accent: .indigo, at: now, horizon: horizon)
    }

    // MARK: Shape

    func testStartsWithNowThenOneEntryPerSlotForTheNextHour() {
        let now = slotStart(7, plus: 100)
        let result = timeline(at: now)

        XCTAssertEqual(result.entries.count, 13)
        XCTAssertEqual(result.entries[0].date, now)
        XCTAssertEqual(result.entries[1].date, slotStart(8))
        XCTAssertEqual(result.entries.last?.date, slotStart(19))
        XCTAssertEqual(result.entries.dropFirst().map(\.date), (8...19).map { slotStart($0) })
    }

    func testStartingExactlyOnABoundaryStillCoversTheHour() {
        let result = timeline(at: slotStart(7))
        XCTAssertEqual(result.entries.count, 13)
        XCTAssertEqual(result.entries.last?.date, slotStart(19))
    }

    func testEntryDatesStrictlyIncrease() {
        let dates = timeline(at: slotStart(3, plus: 299.5)).entries.map(\.date)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(Set(dates).count, dates.count)
    }

    func testRefreshIsRequestedWhenTheLastPreparedSlotEnds() {
        let result = timeline(at: slotStart(7, plus: 100))
        XCTAssertEqual(result.reloadDate, slotStart(20))
        XCTAssertGreaterThan(result.reloadDate, result.entries.last!.date)
    }

    func testCustomHorizon() {
        let result = timeline(at: slotStart(0), horizon: 900) // 15 minutes
        XCTAssertEqual(result.entries.count, 4) // now, +5, +10, +15
        XCTAssertEqual(result.reloadDate, slotStart(4))
    }

    // MARK: Matches the scheduler

    func testEveryEntryShowsWhatTheSchedulerPicksAtItsDate() {
        let result = timeline(at: slotStart(41, plus: 17))
        for entry in result.entries {
            let expected = scheduler.currentCard(in: deck, state: PlaybackState(), at: entry.date)
            XCTAssertEqual(entry.showing?.card, expected?.card, "\(entry.date)")
            XCTAssertEqual(entry.showing?.position, (expected?.index ?? 0) + 1)
        }
    }

    func testAdvancesOneCardPerSlotAndWrapsAround() {
        let result = timeline(at: slotStart(7)) // 10 cards: slots 7..19
        XCTAssertEqual(result.entries.map { $0.showing!.card.front }, (7...19).map { "f\($0 % 10)" })
    }

    func testSkipOffsetCarriesIntoEveryLaterEntry() {
        let t = slotStart(2, plus: 10)
        let skipped = scheduler.skipping(scheduler.skipping(PlaybackState(), in: deck, at: t), in: deck, at: t)
        let result = timeline(at: t, playback: [deck.id: skipped])

        XCTAssertEqual(result.entries[0].showing?.card.front, "f4")
        XCTAssertEqual(result.entries[1].showing?.card.front, "f5")
        XCTAssertEqual(result.entries[2].showing?.card.front, "f6")
    }

    func testFlipAppliesToNowOnly() {
        let t = slotStart(2, plus: 10)
        let flipped = scheduler.flipping(PlaybackState(), in: deck, at: t)
        let result = timeline(at: t, playback: [deck.id: flipped])

        XCTAssertEqual(result.entries[0].showing?.isFlipped, true)
        XCTAssertTrue(result.entries.dropFirst().allSatisfy { $0.showing?.isFlipped == false }, "a new card always starts on its front")
    }

    func testChosenDeckIsUsedForEveryEntry() {
        let other = Deck(name: "Other", cards: [Card(front: "o1", back: "x"), Card(front: "o2", back: "x")])
        let result = FishBrainEntry.timeline(decks: [deck, other], playback: [:], accent: .indigo, at: slotStart(0), deckID: other.id)
        XCTAssertTrue(result.entries.allSatisfy { $0.showing?.deckName == "Other" })
    }

    // MARK: Sleep and wake

    /// WidgetKit shows the latest entry whose date has passed. After the Mac wakes late, that is
    /// still the right card, because every entry was computed from the clock rather than from a
    /// timer that had to fire.
    func testWakingLateStillShowsTheCorrectCard() {
        let result = timeline(at: slotStart(7, plus: 100))

        for minutesLater in [1.0, 4.9, 5.1, 12, 37, 59] {
            let wake = slotStart(7, plus: 100 + minutesLater * 60)
            let shown = result.entries.last { $0.date <= wake }
            let expected = scheduler.currentCard(in: deck, state: PlaybackState(), at: wake)
            XCTAssertEqual(shown?.showing?.card, expected?.card, "woke \(minutesLater) min later")
        }
    }

    // MARK: Nothing to show

    func testEmptyLibraryYieldsOneEntryAndASafetyRefresh() {
        let now = slotStart(5)
        let result = FishBrainEntry.timeline(decks: [], playback: [:], accent: .indigo, at: now)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertNil(result.entries[0].showing)
        XCTAssertEqual(result.reloadDate, now.addingTimeInterval(3600))
    }

    func testDeckWithoutCardsYieldsOneEntry() {
        XCTAssertEqual(timeline(at: slotStart(5), deck: Deck(name: "Empty")).entries.count, 1)
    }
}

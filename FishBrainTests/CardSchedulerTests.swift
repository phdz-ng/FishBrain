import XCTest

final class CardSchedulerTests: XCTestCase {
    private let scheduler = CardScheduler()
    private let interval = CardScheduler.defaultInterval
    private let cards = (0..<3).map { Card(front: "front \($0)", back: "back \($0)") }
    private var deck: Deck { Deck(name: "Test", cards: cards) }

    /// Start of slot `n`, plus an optional offset in seconds.
    private func time(slot n: Int, plus seconds: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: Double(n) * interval + seconds)
    }

    private func index(_ state: PlaybackState = PlaybackState(), deck: Deck? = nil, at date: Date) -> Int? {
        scheduler.currentCard(in: deck ?? self.deck, state: state, at: date)?.index
    }

    // MARK: Rotation

    func testDefaultIntervalIsFiveMinutes() {
        XCTAssertEqual(CardScheduler.defaultInterval, 300)
    }

    func testCardChangesExactlyOnSlotBoundaries() {
        XCTAssertEqual(index(at: time(slot: 0)), 0)
        XCTAssertEqual(index(at: time(slot: 0, plus: interval - 0.001)), 0)
        XCTAssertEqual(index(at: time(slot: 1)), 1)
        XCTAssertEqual(index(at: time(slot: 2, plus: 120)), 2)
    }

    func testRotationWrapsAroundTheDeck() {
        XCTAssertEqual(index(at: time(slot: 3)), 0)
        XCTAssertEqual(index(at: time(slot: 4)), 1)
        XCTAssertEqual(index(at: time(slot: 300_001)), 300_001 % 3)
    }

    func testAllSurfacesAgreeAtTheSameInstant() {
        let now = Date(timeIntervalSince1970: 1_800_000_123)
        XCTAssertEqual(
            scheduler.currentCard(in: deck, state: PlaybackState(), at: now),
            scheduler.currentCard(in: deck, state: PlaybackState(), at: now)
        )
    }

    func testCustomInterval() {
        let fast = CardScheduler(interval: 10)
        let date = Date(timeIntervalSince1970: 25)
        XCTAssertEqual(fast.currentCard(in: deck, state: PlaybackState(), at: date)?.index, 2)
    }

    func testNextRotation() {
        XCTAssertEqual(scheduler.nextRotation(after: time(slot: 5, plus: 10)), time(slot: 6))
        XCTAssertEqual(scheduler.nextRotation(after: time(slot: 5)), time(slot: 6))
    }

    // MARK: Skip

    func testSkipAdvancesImmediatelyAndRotationContinuesFromThere() {
        let t = time(slot: 0, plus: 10)
        let state = scheduler.skipping(PlaybackState(), in: deck, at: t)

        XCTAssertEqual(index(state, at: t), 1)
        XCTAssertEqual(index(state, at: time(slot: 1)), 2)
    }

    func testSkipWrapsAround() {
        var state = PlaybackState()
        let t = time(slot: 0)
        for _ in 0..<3 { state = scheduler.skipping(state, in: deck, at: t) }
        XCTAssertEqual(index(state, at: t), 0)
    }

    func testSkipClearsFlip() {
        let t = time(slot: 0)
        var state = scheduler.flipping(PlaybackState(), in: deck, at: t)
        XCTAssertEqual(scheduler.currentCard(in: deck, state: state, at: t)?.isFlipped, true)

        state = scheduler.skipping(state, in: deck, at: t)
        let current = scheduler.currentCard(in: deck, state: state, at: t)
        XCTAssertEqual(current?.index, 1)
        XCTAssertEqual(current?.isFlipped, false)
        XCTAssertNil(state.flip)
    }

    // MARK: Flip

    func testNewCardStartsOnFront() {
        let current = scheduler.currentCard(in: deck, state: PlaybackState(), at: time(slot: 7))
        XCTAssertEqual(current?.isFlipped, false)
    }

    func testFlipTogglesTheCurrentCard() {
        let t = time(slot: 2, plus: 30)
        var state = scheduler.flipping(PlaybackState(), in: deck, at: t)
        XCTAssertEqual(scheduler.currentCard(in: deck, state: state, at: t)?.isFlipped, true)

        state = scheduler.flipping(state, in: deck, at: t)
        XCTAssertEqual(scheduler.currentCard(in: deck, state: state, at: t)?.isFlipped, false)
    }

    func testFlipResetsWhenRotationMovesToNextCard() {
        let state = scheduler.flipping(PlaybackState(), in: deck, at: time(slot: 0, plus: 5))

        XCTAssertEqual(scheduler.currentCard(in: deck, state: state, at: time(slot: 0, plus: 299))?.isFlipped, true)
        XCTAssertEqual(scheduler.currentCard(in: deck, state: state, at: time(slot: 1))?.isFlipped, false)
    }

    func testFlipDoesNotReappearWhenRotationCyclesBackToTheSameCard() {
        let state = scheduler.flipping(PlaybackState(), in: deck, at: time(slot: 0))
        // Slot 3 shows card 0 again.
        XCTAssertEqual(scheduler.currentCard(in: deck, state: state, at: time(slot: 3))?.isFlipped, false)
    }

    func testFlipResetsEvenWithASingleCardDeck() {
        let single = Deck(name: "One", cards: [Card(front: "a", back: "b")])
        let state = scheduler.flipping(PlaybackState(), in: single, at: time(slot: 0))

        XCTAssertEqual(scheduler.currentCard(in: single, state: state, at: time(slot: 0))?.isFlipped, true)
        XCTAssertEqual(scheduler.currentCard(in: single, state: state, at: time(slot: 1))?.isFlipped, false)
    }

    // MARK: Empty deck

    func testEmptyDeckHasNoCardAndActionsAreNoOps() {
        let empty = Deck(name: "Empty")
        let t = time(slot: 4)
        let state = PlaybackState()

        XCTAssertNil(scheduler.currentCard(in: empty, state: state, at: t))
        XCTAssertEqual(scheduler.flipping(state, in: empty, at: t), state)
        XCTAssertEqual(scheduler.skipping(state, in: empty, at: t), state)
    }

    // MARK: Adding and removing cards

    func testAddingACardChangesTheRotationModulus() {
        let t = time(slot: 4) // 4 % 3 == 1
        XCTAssertEqual(index(at: t), 1)

        var bigger = deck
        bigger.cards.append(Card(front: "new", back: "new"))
        XCTAssertEqual(index(deck: bigger, at: t), 0) // 4 % 4
    }

    func testRemovingACardChangesTheRotationModulus() {
        var smaller = deck
        smaller.cards.removeLast()
        XCTAssertEqual(index(deck: smaller, at: time(slot: 5)), 1) // 5 % 2
    }

    func testRemovingTheLastCardLeavesAnEmptyDeck() {
        var one = Deck(name: "One", cards: [cards[0]])
        one.cards.removeAll()
        XCTAssertNil(index(deck: one, at: time(slot: 1)))
    }

    func testFlipIsDroppedWhenEditsChangeWhichCardIsShown() {
        let t = time(slot: 4) // shows cards[1]
        let state = scheduler.flipping(PlaybackState(), in: deck, at: t)
        XCTAssertEqual(scheduler.currentCard(in: deck, state: state, at: t)?.isFlipped, true)

        var edited = deck
        edited.cards.insert(Card(front: "inserted", back: "inserted"), at: 0) // now 4 % 4 == 0, a different card
        let current = scheduler.currentCard(in: edited, state: state, at: t)
        XCTAssertEqual(current?.index, 0)
        XCTAssertEqual(current?.isFlipped, false)
    }

    func testFlipSurvivesEditsThatDoNotChangeTheShownCard() {
        let t = time(slot: 0) // shows cards[0]
        let state = scheduler.flipping(PlaybackState(), in: deck, at: t)

        var edited = deck
        edited.cards[2].front = "edited elsewhere"
        XCTAssertEqual(scheduler.currentCard(in: edited, state: state, at: t)?.isFlipped, true)
    }

    // MARK: State

    func testPlaybackStateRoundTripsThroughJSON() throws {
        var state = PlaybackState()
        state = scheduler.skipping(state, in: deck, at: time(slot: 1))
        state = scheduler.flipping(state, in: deck, at: time(slot: 1))

        let decoded = try JSONDecoder().decode(PlaybackState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }
}

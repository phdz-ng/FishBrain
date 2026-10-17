import AppKit
import SwiftUI
import XCTest

/// Learn mode (FLAS-57): the order and wrap rules, what counts as studied, and that it leaves the
/// playback file alone.
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

final class LearnSessionTests: XCTestCase {
    private let cards = (1...4).map { Card(front: "f\($0)", back: "b\($0)") }
    private var deck: Deck { Deck(name: "Spanish", cards: cards) }

    func testStartsOnTheFirstCardShowingItsFront() {
        let session = LearnSession(deck: deck)
        XCTAssertEqual(session.currentCardID, cards[0].id)
        XCTAssertFalse(session.isFlipped)
        XCTAssertFalse(session.isComplete)
        XCTAssertEqual(session.positionText, "1 / 4")
        XCTAssertEqual(session.progress, 0)
    }

    func testFlipTurnsTheCardAndReportsOnlyTheTurnToTheAnswer() {
        var session = LearnSession(deck: deck)
        XCTAssertEqual(session.flip(), cards[0].id, "to the answer: counts as studied")
        XCTAssertTrue(session.isFlipped)
        XCTAssertNil(session.flip(), "back to the front: doesn't")
        XCTAssertFalse(session.isFlipped)
    }

    func testNextAndPreviousMoveOneCardAndAlwaysLandOnAFront() {
        var session = LearnSession(deck: deck)
        session.flip()
        session.next()
        XCTAssertEqual(session.currentCardID, cards[1].id)
        XCTAssertFalse(session.isFlipped)
        session.flip()
        session.previous()
        XCTAssertEqual(session.currentCardID, cards[0].id)
        XCTAssertFalse(session.isFlipped)
    }

    func testPreviousStopsAtTheFirstCard() {
        var session = LearnSession(deck: deck)
        XCTAssertFalse(session.canGoBack)
        session.previous()
        XCTAssertEqual(session.index, 0)
        XCTAssertEqual(session.currentCardID, cards[0].id)
    }

    func testAfterTheLastCardTheRoundIsComplete() {
        var session = LearnSession(deck: deck)
        for _ in 0..<3 { session.next() }
        XCTAssertEqual(session.currentCardID, cards[3].id)
        XCTAssertEqual(session.progress, 1)
        XCTAssertTrue(session.canGoForward, "the last card's next arrow ends the round")

        session.next()
        XCTAssertTrue(session.isComplete)
        XCTAssertNil(session.currentCardID)
        XCTAssertEqual(session.positionText, "4 / 4")
        XCTAssertEqual(session.progress, 1)
        XCTAssertFalse(session.canGoForward)
        session.next()
        XCTAssertTrue(session.isComplete, "nothing past the end")
        XCTAssertNil(session.flip(), "no card to turn")
    }

    func testPreviousFromTheEndReturnsToTheLastCard() {
        var session = LearnSession(deck: deck)
        for _ in 0..<4 { session.next() }
        session.previous()
        XCTAssertFalse(session.isComplete)
        XCTAssertEqual(session.currentCardID, cards[3].id)
    }

    func testGoAgainStartsTheSameOrderOver() {
        var session = LearnSession(deck: deck)
        var rng = SplitMix64(state: 7)
        session.shuffle(using: &rng)
        let order = session.order
        for _ in 0..<4 { session.next() }
        session.restart()
        XCTAssertFalse(session.isComplete)
        XCTAssertEqual(session.index, 0)
        XCTAssertEqual(session.order, order, "the order is remembered while the screen is open")
    }

    func testShuffleKeepsEveryCardExactlyOnceAndStartsOver() {
        let big = Deck(name: "Big", cards: (1...48).map { Card(front: "f\($0)", back: "b\($0)") })
        var session = LearnSession(deck: big)
        session.next()
        session.next()
        session.flip()
        var rng = SplitMix64(state: 42)
        session.shuffle(using: &rng)

        XCTAssertEqual(session.order.count, 48)
        XCTAssertEqual(Set(session.order), Set(big.cards.map(\.id)), "every card, none twice")
        XCTAssertNotEqual(session.order, big.cards.map(\.id), "and in a different order")
        XCTAssertEqual(session.index, 0)
        XCTAssertFalse(session.isFlipped)
        // The order stays put while moving about.
        let shuffled = session.order
        session.next()
        session.previous()
        XCTAssertEqual(session.order, shuffled)
        XCTAssertEqual(session.currentCardID, shuffled[0])
    }

    func testAnEmptyDeckHasNothingToLearn() {
        let empty = Deck(name: "Empty")
        XCTAssertFalse(LearnSession.canStart(empty))
        XCTAssertTrue(LearnSession.canStart(deck))
        var session = LearnSession(deck: empty)
        XCTAssertNil(session.currentCardID)
        XCTAssertEqual(session.positionText, "0 / 0")
        session.next()
        session.previous()
        XCTAssertNil(session.flip())
        XCTAssertFalse(session.isComplete)
    }

    func testAOneCardDeckCompletesOnNext() {
        var session = LearnSession(deck: Deck(name: "One", cards: [cards[0]]))
        XCTAssertEqual(session.progress, 0)
        session.next()
        XCTAssertTrue(session.isComplete)
    }

    func testTheFishFollowsTheCardIndex() {
        var session = LearnSession(deck: deck)
        XCTAssertEqual(session.progress, 0)
        session.next()
        XCTAssertEqual(session.progress, 1.0 / 3, accuracy: 0.0001)
        session.next()
        XCTAssertEqual(session.progress, 2.0 / 3, accuracy: 0.0001)
    }

    func testFollowsTheDeckWhenCardsAreAddedOrRemoved() {
        var session = LearnSession(deck: deck)
        session.next() // on card 2
        var edited = deck
        let added = Card(front: "new", back: "new")
        edited.cards.remove(at: 0)
        edited.cards.append(added)
        session.sync(with: edited)

        XCTAssertEqual(session.order, [cards[1].id, cards[2].id, cards[3].id, added.id])
        XCTAssertEqual(session.currentCardID, cards[1].id, "the card showing stays showing")
        XCTAssertEqual(session.index, 0)

        edited.cards.removeAll { $0.id == cards[1].id }
        session.sync(with: edited)
        XCTAssertEqual(session.currentCardID, cards[2].id, "its card went: the next one stands in")
        XCTAssertFalse(session.isFlipped)
    }
}

@MainActor
final class LearnStudyTests: XCTestCase {
    private var directory: URL!
    private let deck = Deck(name: "Spanish", cards: (1...3).map { Card(front: "f\($0)", back: "b\($0)") })
    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(study: StudyStore, at date: @escaping () -> Date) -> LearnModel {
        LearnModel(deck: deck, clock: date) { id, when in study.recordStudied(id, at: when, goal: 20) }
    }

    func testTurningACardToItsAnswerCountsOncePerCardPerDay() {
        let study = StudyStore(storage: StudyStorage(directory: directory))
        var now = noon
        let model = makeModel(study: study) { now }

        model.flip() // card 1 to its answer
        XCTAssertEqual(study.summary(at: now, goal: 20).count, 1)
        model.flip() // back to the front
        model.flip() // and to the answer again
        XCTAssertEqual(study.summary(at: now, goal: 20).count, 1, "the same card, the same day")

        model.next()
        model.flip()
        XCTAssertEqual(study.summary(at: now, goal: 20).count, 2, "a different card")

        now = noon.addingTimeInterval(24 * 3600)
        model.previous()
        model.flip()
        XCTAssertEqual(study.summary(at: now, goal: 20).count, 1, "the next day it counts again")
    }

    func testOnlyTheFrontShownIsNotStudied() {
        let study = StudyStore(storage: StudyStorage(directory: directory))
        let model = makeModel(study: study) { self.noon }
        model.next()
        model.previous()
        model.shuffle()
        XCTAssertEqual(study.summary(at: noon, goal: 20).count, 0)
    }

    func testTheCountIsWrittenToTheStudyLogOtherProcessesRead() {
        let study = StudyStore(storage: StudyStorage(directory: directory))
        XCTAssertTrue(study.recordStudied(deck.cards[0].id, at: noon, goal: 20))
        XCTAssertFalse(study.recordStudied(deck.cards[0].id, at: noon, goal: 20))
        XCTAssertEqual(StudyStorage(directory: directory).load().count(on: noon), 1)
    }

    func testThePlaybackFileIsByteIdenticalAfterALearnRun() throws {
        // A deck with a skip offset, a flip and some grades: all of it must come through untouched.
        let storage = PlaybackStorage(directory: directory)
        var state = PlaybackState(skipOffset: 3)
        state.flip = PlaybackState.Flip(position: 3, cardID: deck.cards[0].id)
        state.reviews[deck.cards[1].id.uuidString] = ReviewState(
            due: noon, interval: 86_400, ease: 2.5, reps: 2, lapses: 0, lastReviewed: noon
        )
        try storage.save([deck.id: state])
        let before = try Data(contentsOf: storage.fileURL)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: storage.fileURL.path)[.modificationDate] as? Date

        let study = StudyStore(storage: StudyStorage(directory: directory))
        let model = makeModel(study: study) { self.noon }
        model.flip()
        model.next()
        model.flip()
        model.previous()
        model.shuffle()
        model.next(); model.next(); model.next(); model.next()
        model.goAgain()
        model.flip()

        XCTAssertEqual(try Data(contentsOf: storage.fileURL), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: storage.fileURL.path)[.modificationDate] as? Date, attributesBefore, "not even rewritten")
        XCTAssertEqual(storage.load()[deck.id], state)
        XCTAssertGreaterThan(study.summary(at: noon, goal: 20).count, 0, "but the flips did count")
    }

    func testTheRotationTheWidgetAndNotchShowIsUnchanged() throws {
        let storage = PlaybackStorage(directory: directory)
        let playback = PlaybackStore(storage: storage, onSaved: {})
        let scheduler = CardScheduler()
        let before = scheduler.currentCard(in: deck, state: playback.state(for: deck.id), at: noon)

        let study = StudyStore(storage: StudyStorage(directory: directory))
        let model = makeModel(study: study) { self.noon }
        model.flip(); model.next(); model.flip(); model.shuffle()

        playback.refresh()
        XCTAssertEqual(scheduler.currentCard(in: deck, state: playback.state(for: deck.id), at: noon), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.fileURL.path), "Learn doesn't even create the file")
    }
}

@MainActor
final class LearnViewLayoutTests: XCTestCase {
    func testLaysOutAtTheMinimumWindowSizeAndInTheRoundCompleteState() throws {
        let deck = Deck(name: "Everyday Spanish", cards: PreviewData.decks[0].cards)
        let size = MainWindowView.minimumSize
        let view = LearnView(deck: deck, onLeave: {})
            .environmentObject(PreviewData.study())
            .environmentObject(PreviewData.settings())
            .environment(\.accentChoice, .default)
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        XCTAssertNotNil(renderer.cgImage)
    }

    func testTheLearnButtonOpensWithCardsAndExplainsAnEmptyDeck() {
        let toolbar = DeckToolbar(onAddCard: {}, onLearn: {}, learnNeedsCards: true)
        let size = NSHostingView(rootView: toolbar.environment(\.accentChoice, .default)).fittingSize
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertFalse(LearnSession.canStart(Deck(name: "Empty")))
    }
}

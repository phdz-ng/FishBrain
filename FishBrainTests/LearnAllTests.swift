import SwiftUI
import XCTest

/// Learn all and Review… for a whole subject (FLAS-67).
private struct SpanishShelf {
    let spanish = Subject(name: "Spanish")
    let grammar: Subject
    let verbs: Subject
    let vocab: Subject
    let emptySubject = Subject(name: "Nothing yet")
    let cardless: Subject
    let regular: Deck, irregular: Deck, tenses: Deck, words: Deck, everyday: Deck, loose: Deck, emptyDeck: Deck

    init() {
        grammar = Subject(name: "Grammar", parentID: spanish.id)
        verbs = Subject(name: "Verbs", parentID: grammar.id)
        vocab = Subject(name: "Vocabulary", parentID: spanish.id)
        cardless = Subject(name: "Cardless")
        func deck(_ name: String, _ n: Int, in subject: Subject?) -> Deck {
            Deck(name: name, cards: (1...n).map { Card(front: "\(name) \($0)", back: "back") }, subjectID: subject?.id)
        }
        regular = deck("Regular verbs", 3, in: verbs)
        irregular = deck("Irregular verbs", 2, in: verbs)
        tenses = deck("Tenses", 2, in: grammar)
        words = deck("Words", 3, in: vocab)
        everyday = deck("Everyday Spanish", 4, in: spanish)
        loose = deck("World Capitals", 5, in: nil)
        emptyDeck = Deck(name: "No cards", cards: [], subjectID: cardless.id)
    }

    var subjects: [Subject] { [spanish, grammar, verbs, vocab, emptySubject, cardless] }
    /// In library order, which is not the outline order.
    var decks: [Deck] { [everyday, words, tenses, loose, regular, irregular, emptyDeck] }
    var tree: SubjectTree { SubjectTree(subjects) }

    func summary(_ subject: Subject, playback: [Deck.ID: PlaybackState] = [:]) -> SubjectSummary {
        SubjectSummary(subject: subject.id, tree: tree, decks: decks, playback: playback, now: Date(timeIntervalSince1970: 1_800_000_000))
    }
}

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

final class LearnAllOrderTests: XCTestCase {
    private let shelf = SpanishShelf()

    func testDecksComeInOutlineOrderSubSubjectsFirstThenTheSubjectsOwn() {
        let ordered = shelf.tree.decksInOutlineOrder(of: shelf.spanish.id, among: shelf.decks)
        XCTAssertEqual(ordered.map(\.name), ["Regular verbs", "Irregular verbs", "Tenses", "Words", "Everyday Spanish"])
        XCTAssertEqual(
            shelf.tree.decksInOutlineOrder(of: shelf.grammar.id, among: shelf.decks).map(\.name),
            ["Regular verbs", "Irregular verbs", "Tenses"]
        )
        XCTAssertEqual(shelf.tree.decksInOutlineOrder(of: shelf.verbs.id, among: shelf.decks).map(\.name), ["Regular verbs", "Irregular verbs"])
        XCTAssertTrue(shelf.tree.decksInOutlineOrder(of: shelf.emptySubject.id, among: shelf.decks).isEmpty)
        XCTAssertTrue(shelf.tree.decksInOutlineOrder(of: UUID(), among: shelf.decks).isEmpty)
    }

    func testTheOrderMatchesTheRowsTheReviewSheetShows() {
        let rows = ReviewChecklist.rows(subjects: shelf.subjects, decks: shelf.decks, ticked: [], playback: [:], now: Date())
        let sheetOrder = rows.compactMap { row -> String? in
            if case .deck = row.kind { row.name } else { nil }
        }.filter { ["Regular verbs", "Irregular verbs", "Tenses", "Words", "Everyday Spanish"].contains($0) }
        XCTAssertEqual(sheetOrder, shelf.tree.decksInOutlineOrder(of: shelf.spanish.id, among: shelf.decks).map(\.name))
    }

    func testCardsGoDeckByDeckInThatOrder() {
        let ordered = shelf.tree.decksInOutlineOrder(of: shelf.spanish.id, among: shelf.decks)
        var session = LearnSession(decks: ordered)
        XCTAssertEqual(session.total, 3 + 2 + 2 + 3 + 4)
        XCTAssertEqual(session.positionText, "1 / 14")
        var fronts: [String] = []
        let byID = Dictionary(uniqueKeysWithValues: ordered.flatMap(\.cards).map { ($0.id, $0.front) })
        while let id = session.currentCardID {
            fronts.append(byID[id]!)
            session.next()
        }
        XCTAssertEqual(fronts.prefix(5), ["Regular verbs 1", "Regular verbs 2", "Regular verbs 3", "Irregular verbs 1", "Irregular verbs 2"])
        XCTAssertEqual(fronts.suffix(4), (1...4).map { "Everyday Spanish \($0)" })
        XCTAssertTrue(session.isComplete)
    }

    func testAcardInTwoPlacesIsGoneThroughOnce() {
        let twin = shelf.regular
        let session = LearnSession(decks: [twin, twin])
        XCTAssertEqual(session.total, 3)
    }

    func testShuffleAcrossDecksKeepsEveryCardExactlyOnce() {
        let ordered = shelf.tree.decksInOutlineOrder(of: shelf.spanish.id, among: shelf.decks)
        let all = Set(ordered.flatMap(\.cards).map(\.id))
        var session = LearnSession(decks: ordered)
        session.next()
        session.next()
        var rng = SplitMix64(state: 5)
        session.shuffle(using: &rng)
        XCTAssertEqual(session.order.count, all.count)
        XCTAssertEqual(Set(session.order), all, "every card, none twice")
        XCTAssertEqual(session.index, 0)
        XCTAssertNotEqual(session.order, ordered.flatMap(\.cards).map(\.id))
        // Mixed across decks: the first few aren't all from the first deck.
        let firstDeck = Set(ordered[0].cards.map(\.id))
        XCTAssertFalse(session.order.prefix(3).allSatisfy(firstDeck.contains))
    }

    func testFollowsTheDecksWhenOneIsEmptiedOrAdded() {
        var ordered = shelf.tree.decksInOutlineOrder(of: shelf.spanish.id, among: shelf.decks)
        var session = LearnSession(decks: ordered)
        let current = session.currentCardID
        ordered.removeAll { $0.id == shelf.words.id }
        session.sync(with: ordered)
        XCTAssertEqual(session.total, 11)
        XCTAssertEqual(session.currentCardID, current)
        var added = shelf.everyday
        added.cards.append(Card(front: "new", back: "new"))
        ordered[ordered.count - 1] = added
        session.sync(with: ordered)
        XCTAssertEqual(session.total, 12)
    }
}

@MainActor
final class LearnAllStudyTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let shelf = SpanishShelf()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testFlipsAcrossDecksCountTowardTheGoalOnceEachAndChangeNoSchedule() throws {
        let storage = PlaybackStorage(directory: directory)
        var state = PlaybackState(skipOffset: 2)
        state.reviews[shelf.regular.cards[0].id.uuidString] = ReviewState(
            due: now, interval: 86_400, ease: 2.5, reps: 2, lapses: 0, lastReviewed: now.addingTimeInterval(-86_400)
        )
        try storage.save([shelf.regular.id: state])
        let before = try Data(contentsOf: storage.fileURL)

        let study = StudyStore(storage: StudyStorage(directory: directory))
        let ordered = shelf.tree.decksInOutlineOrder(of: shelf.spanish.id, among: shelf.decks)
        let model = LearnModel(decks: ordered, clock: { self.now }) { id, date in
            study.recordStudied(id, at: date, goal: 20)
        }
        // Three cards of Regular verbs, then the first of Irregular verbs; one of them flipped twice.
        for _ in 0..<3 {
            model.flip()
            model.next()
        }
        model.flip()
        model.flip() // back to the front
        model.flip() // and to the answer again

        XCTAssertEqual(study.summary(at: now, goal: 20).count, 4, "each card once")
        XCTAssertEqual(try Data(contentsOf: storage.fileURL), before, "no schedule, no rotation changed")
    }
}

final class SubjectLearnReviewButtonTests: XCTestCase {
    private let shelf = SpanishShelf()

    func testAnEmptySubjectDisablesBothWithAReason() {
        let s = shelf.summary(shelf.emptySubject)
        XCTAssertEqual(s.cardsAvailability, .disabled("There are no decks in this subject yet."))
        XCTAssertFalse(s.cardsAvailability.isEnabled)
        XCTAssertNotNil(s.cardsAvailability.reason)
    }

    func testASubjectWhoseDecksHaveNoCardsIsOffToo() {
        XCTAssertEqual(shelf.summary(shelf.cardless).cardsAvailability, .disabled("There are no cards in this subject yet."))
    }

    func testASubjectHoldingOnlyOtherSubjectsWithCardsIsOn() {
        // Grammar's own deck is Tenses; Spanish holds Grammar and Vocabulary, with decks at every level.
        XCTAssertEqual(shelf.summary(shelf.spanish).cardsAvailability, .enabled)
        XCTAssertEqual(shelf.summary(shelf.grammar).cardsAvailability, .enabled)
        let wrapper = Subject(name: "Wrapper")
        let inner = Subject(name: "Inner", parentID: wrapper.id)
        let deck = Deck(name: "Deep", cards: [Card(front: "a", back: "b")], subjectID: inner.id)
        let s = SubjectSummary(subject: wrapper.id, tree: SubjectTree([wrapper, inner]), decks: [deck], playback: [:], now: Date())
        XCTAssertEqual(s.cardsAvailability, .enabled, "a deck two levels down counts")
    }

    func testReviewOpensTheSheetWithEveryDeckInsideTicked() {
        let ids = Set(shelf.tree.decksInOutlineOrder(of: shelf.spanish.id, among: shelf.decks).map(\.id))
        XCTAssertEqual(ids, [shelf.regular.id, shelf.irregular.id, shelf.tenses.id, shelf.words.id, shelf.everyday.id])
        XCTAssertFalse(ids.contains(shelf.loose.id))
        // As the sheet shows it: the subject on, with a dash nowhere inside.
        let rows = ReviewChecklist.rows(subjects: shelf.subjects, decks: shelf.decks, ticked: ids, playback: [:], now: Date())
        XCTAssertEqual(rows.first { $0.name == "Spanish" }?.tick, .on)
        XCTAssertEqual(rows.first { $0.name == "Grammar" }?.tick, .on)
        XCTAssertEqual(rows.first { $0.name == "World Capitals" }?.tick, .off)
        let setup = ReviewSetup(ticking: ids)
        let summary = ReviewSetupSummary(decks: shelf.decks, playback: [:], setup: setup, now: Date())
        XCTAssertEqual(summary.tickedDecks, 5)
        XCTAssertEqual(summary.total, 3 + 2 + 2 + 3 + 4)
    }

    func testASubSubjectTileTicksOnlyItsOwnDecks() {
        let ids = Set(shelf.tree.decksInOutlineOrder(of: shelf.grammar.id, among: shelf.decks).map(\.id))
        XCTAssertEqual(ids, [shelf.regular.id, shelf.irregular.id, shelf.tenses.id])
    }
}

@MainActor
final class LearnAllLayoutTests: XCTestCase {
    func testLearnAllLaysOutAtTheMinimumWindowSize() {
        let shelf = SpanishShelf()
        let ordered = shelf.tree.decksInOutlineOrder(of: shelf.spanish.id, among: shelf.decks)
        let view = LearnView(title: "Spanish", decks: ordered, isWholeSubject: true, onLeave: {})
            .environmentObject(PreviewData.study())
            .environmentObject(PreviewData.settings())
            .environment(\.accentChoice, .default)
            .frame(width: MainWindowView.minimumSize.width, height: MainWindowView.minimumSize.height)
            .preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        XCTAssertNotNil(renderer.cgImage)
    }

    func testTheSubjectTileShowsLearnAndReview() {
        let shelf = SpanishShelf()
        let tile = SubjectTile(subject: shelf.grammar, summary: shelf.summary(shelf.grammar), onOpen: {})
            .environment(\.accentChoice, .default)
            .frame(width: 320)
            .preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: tile)
        renderer.scale = 1
        XCTAssertNotNil(renderer.cgImage)
    }
}

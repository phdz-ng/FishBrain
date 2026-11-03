import AppKit
import SwiftUI
import XCTest

/// Grading in the deck view (FLAS-56): the Status chip, the four buttons under Now showing, and the
/// toolbar that had to make room for Learn and Review.
final class CardStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day = ReviewScheduler.day
    private let minute = ReviewScheduler.minute

    private func review(due: TimeInterval, reps: Int = 3) -> ReviewState {
        ReviewState(due: now.addingTimeInterval(due), interval: max(due, day), ease: 2.5, reps: reps, lapses: 0, lastReviewed: now)
    }

    func testACardNobodyHasGradedIsNew() {
        XCTAssertEqual(CardStatus(nil, at: now), .new)
        XCTAssertEqual(CardStatus.new.text, "New")
    }

    func testACardBeingLearnedShowsHowLongUntilItIsBack() {
        let status = CardStatus(review(due: 10 * minute, reps: 0), at: now)
        XCTAssertEqual(status, .learning(10 * minute))
        XCTAssertEqual(status.text, "Learning · 10 min")
    }

    func testACardWhoseTimeHasComeIsDueNow() {
        XCTAssertEqual(CardStatus(review(due: -3 * day), at: now), .dueNow)
        XCTAssertEqual(CardStatus(review(due: 0), at: now), .dueNow, "exactly at its time is due")
        XCTAssertEqual(CardStatus(review(due: -minute, reps: 0), at: now), .dueNow, "a learning card that came back too")
        XCTAssertEqual(CardStatus.dueNow.text, "Due now")
    }

    func testAGraduatedCardShowsTheDaysUntilItsNextReview() {
        let status = CardStatus(review(due: 4 * day), at: now)
        XCTAssertEqual(status, .upcoming(4 * day))
        XCTAssertEqual(status.text, "In 4 days")
        XCTAssertEqual(CardStatus(review(due: day), at: now).text, "In 1 day")
        XCTAssertEqual(CardStatus(review(due: 5 * 3600), at: now).text, "In 5 h")
    }

    func testMasteredStartsAtTwentyOneDays() {
        XCTAssertEqual(CardStatus.masteredThreshold, 21 * day)
        XCTAssertEqual(CardStatus(review(due: 21 * day - 1), at: now).tone, .neutral, "a second short is still In N days")
        XCTAssertEqual(CardStatus(review(due: 21 * day), at: now), .mastered(21 * day))
        XCTAssertEqual(CardStatus(review(due: 21 * day), at: now).text, "Mastered · 21 days")
        XCTAssertEqual(CardStatus(review(due: 90 * day), at: now).text, "Mastered · 3 mo")
        XCTAssertEqual(CardStatus(review(due: 400 * day), at: now).text, "Mastered · 1 yr")
    }

    func testEveryStateHasItsOwnTone() {
        XCTAssertEqual(CardStatus.new.tone, .neutral)
        XCTAssertEqual(CardStatus.upcoming(day).tone, .neutral)
        XCTAssertEqual(CardStatus.learning(minute).tone, .learning)
        XCTAssertEqual(CardStatus.dueNow.tone, .due)
        XCTAssertEqual(CardStatus.mastered(30 * day).tone, .mastered)
    }

    func testTheSpokenStatus() {
        XCTAssertEqual(CardStatus.new.accessibilityText, "Status, new")
        XCTAssertEqual(CardStatus.dueNow.accessibilityText, "Status, due now")
        XCTAssertEqual(CardStatus.learning(10 * minute).accessibilityText, "Status, learning, 10 min")
        XCTAssertEqual(CardStatus.upcoming(4 * day).accessibilityText, "Status, in 4 days")
        XCTAssertEqual(CardStatus.mastered(90 * day).accessibilityText, "Status, mastered, 3 mo")
    }

    func testTheChipsAreLegibleOnTheListSurface() {
        for scheme in [ColorScheme.light, .dark] {
            assertChipsAreLegible(in: scheme)
        }
    }

    private func assertChipsAreLegible(in scheme: ColorScheme) {
        let window = Theme.Surface.window.swatch(for: scheme).composited(over: Swatch(0x000000))
        let surface = Theme.Surface.group.swatch(for: scheme).composited(over: window)
        var pairs: [(String, Token, Token)] = [
            ("neutral", Theme.TextColor.cardBack, Theme.Surface.control),
            ("learning", Theme.Status.learning, Theme.Status.learning.with(opacity: 0.18)),
            ("mastered", Theme.Status.ok, Theme.Status.ok.with(opacity: 0.16)),
        ]
        for accent in AccentChoice.allCases { pairs.append(("due, \(accent)", accent.light, accent.flippedSurface)) }
        for (name, text, fill) in pairs {
            let ratio = text.swatch(for: scheme).contrast(with: fill.swatch(for: scheme).composited(over: surface))
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) in \(scheme): \(ratio)")
        }
    }
}

@MainActor
final class DeckGradingTests: XCTestCase {
    private var directory: URL!
    private var storage: PlaybackStorage!
    private let deck = Deck(name: "Everyday Spanish", cards: (1...4).map { Card(front: "f\($0)", back: "b\($0)") })
    /// The start of slot 0, so the rotation shows the deck's first card.
    private let t = Date(timeIntervalSince1970: 100)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = PlaybackStorage(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> PlaybackStore { PlaybackStore(storage: storage, onSaved: {}) }

    private func showing(_ store: PlaybackStore) -> NowShowing? {
        NowShowing.make(deck: deck, state: store.state(for: deck.id), at: t)
    }

    // MARK: The buttons

    func testTheButtonsAreOffUntilTheCardIsTurnedOver() {
        let store = makeStore()
        XCTAssertFalse(NowShowingPanel.canGrade(showing(store)), "the front is showing")
        XCTAssertFalse(NowShowingPanel.canGrade(nil), "an empty deck has nothing to grade")

        store.flip(deck, at: t)
        XCTAssertTrue(NowShowingPanel.canGrade(showing(store)))

        store.flip(deck, at: t) // back to the front
        XCTAssertFalse(NowShowingPanel.canGrade(showing(store)))
    }

    func testTheButtonsSayWhenTheCardWouldComeBack() throws {
        let store = makeStore()
        store.flip(deck, at: t)
        let intervals = try XCTUnwrap(showing(store)).gradeIntervals
        XCTAssertEqual(ReviewGrade.allCases.map { GradeButtons.accessibilityLabel($0, intervals) }, [
            "Again, next in 1 min", "Hard, next in 10 min", "Good, next in 1 day", "Easy, next in 4 days",
        ])

        let graduated = ReviewState(due: t, interval: 6 * ReviewScheduler.day, ease: 2.5, reps: 3, lapses: 0, lastReviewed: t)
        XCTAssertEqual(
            GradeButtons.accessibilityLabel(.good, ReviewScheduler.intervals(from: graduated)),
            "Good, next in 15 days", "the spoken form in the ticket"
        )
    }

    // MARK: Grading from the panel

    func testGradingUpdatesTheStoreAndMovesToTheNextCard() throws {
        let store = makeStore()
        store.flip(deck, at: t)
        let first = try XCTUnwrap(showing(store)).card

        store.grade(.good, deck, at: t)

        let review = try XCTUnwrap(store.state(for: deck.id).review(for: first.id))
        XCTAssertEqual(review.due, t.addingTimeInterval(ReviewScheduler.day))
        XCTAssertEqual(review.reps, 1)
        let next = try XCTUnwrap(showing(store))
        XCTAssertEqual(next.card.front, "f2", "moved on")
        XCTAssertFalse(next.isFlipped)
        XCTAssertFalse(NowShowingPanel.canGrade(next), "the next card has to be turned over too")
    }

    func testTheNotchAndWidgetSeeTheSameGrade() throws {
        let app = makeStore()
        app.flip(deck, at: t)
        app.grade(.easy, deck, at: t)

        // The notch and the widget are other processes reading the same playback file.
        let notch = makeStore()
        XCTAssertEqual(notch.state(for: deck.id), app.state(for: deck.id))
        XCTAssertEqual(NowShowing.make(deck: deck, state: notch.state(for: deck.id), at: t), showing(app))
    }

    func testGradingBeforeTurningOverDoesNothing() {
        let store = makeStore()
        store.grade(.good, deck, at: t)
        XCTAssertTrue(store.state(for: deck.id).reviews.isEmpty)
        XCTAssertEqual(showing(store)?.card.front, "f1")
    }

    func testTheCountLineGrowsAsCardsAreTurnedOver() {
        let store = makeStore()
        let study = StudyStore(storage: StudyStorage(directory: directory))
        XCTAssertEqual(study.summary(at: t, goal: 30).openLine, "0 of 30 today")

        store.flip(deck, at: t)
        store.grade(.good, deck, at: t)
        study.refresh()
        XCTAssertEqual(study.summary(at: t, goal: 30).openLine, "1 of 30 today")
    }

    // MARK: Layout

    private func fittingSize<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: view.environment(\.accentChoice, .default).preferredColorScheme(.dark)).fittingSize
    }

    func testThePanelIs280PointsWide() {
        XCTAssertEqual(NowShowingPanel.side, 280)
        let size = fittingSize(NowShowingPanel(deck: deck, state: PlaybackState(), onFlip: {}, onSkip: {}))
        XCTAssertEqual(size.width, 280, accuracy: 0.5)
    }

    func testThePanelKeepsItsHeightWhenTheCardTurnsOver() {
        let scheduler = CardScheduler()
        let front = PlaybackState()
        let back = scheduler.flipping(front, in: deck, at: Date())
        XCTAssertNotNil(back.flip)
        let a = fittingSize(NowShowingPanel(deck: deck, state: front, onFlip: {}, onSkip: {}, studySummary: { _ in .sample }))
        let b = fittingSize(NowShowingPanel(deck: deck, state: back, onFlip: {}, onSkip: {}, studySummary: { _ in .sample }))
        XCTAssertEqual(a.height, b.height, accuracy: 0.5)
        XCTAssertGreaterThan(a.height, NowShowingPanel.side + 48, "the card, the four buttons and the line under it")
    }

    func testTheToolbarFitsAtTheMinimumWindowWidth() {
        let toolbar = DeckToolbar(
            onAddCard: {}, onImportCSV: {}, onPasteCards: {}, onGenerate: {}, generateAvailability: .available
        )
        let content = MainWindowView.minimumSize.width - MainWindowView.sidebarWidth - 0.5 - 2 * 32
        let width = fittingSize(toolbar).width
        XCTAssertLessThanOrEqual(width, content, "the toolbar's natural width, \(width), fits the window's content, \(content)")
        // Beside the 30 pt title block it still shares the row, as before.
        XCTAssertLessThanOrEqual(width, content - 300 - 16)
    }

    func testTheCardGivesUpHeightInAShortWindowButNeverBelowItsFloor() {
        XCTAssertEqual(NowShowingPanel.cardHeight(available: 800), 280, "square when there is room")
        XCTAssertEqual(NowShowingPanel.cardHeight(available: 452), 280)
        XCTAssertEqual(NowShowingPanel.cardHeight(available: 330), 158)
        XCTAssertEqual(NowShowingPanel.cardHeight(available: 100), NowShowingPanel.minimumCardHeight)
    }

    func testTheCardListChoosesItsRowLayoutByWidth() {
        XCTAssertEqual(CardEditor.RowLayout(width: 832), .columns)
        XCTAssertEqual(CardEditor.RowLayout(width: 520), .columns)
        XCTAssertEqual(CardEditor.RowLayout(width: 432), .chipBelow, "the default window")
        XCTAssertEqual(CardEditor.RowLayout(width: 311), .stacked, "the minimum window")
    }

    func testTheDeckViewLaysOutAtTheMinimumWindowSizeWithGradingShowing() throws {
        let store = PreviewData.store()
        let deck = try XCTUnwrap(store.decks.first)
        let playback = PreviewData.playback()
        let size = MainWindowView.minimumSize
        let view = DeckContentView(
            deck: deck, isRenaming: .constant(false), cardFocusRequest: .constant(nil),
            onRename: { _ in }, onSetColor: { _ in }, onNewDeck: {}, onAddCard: {}
        )
        .environmentObject(store)
        .environmentObject(playback)
        .environmentObject(PreviewData.study())
        .environmentObject(PreviewData.settings())
        .environmentObject(PreviewData.composer())
        .frame(width: size.width - MainWindowView.sidebarWidth, height: size.height)
        .preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        XCTAssertNotNil(renderer.cgImage)
    }
}

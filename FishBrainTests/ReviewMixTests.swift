import SwiftUI
import XCTest

/// Mixing subjects and decks in one Review sprint (FLAS-66).
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private struct Mix {
    let spanish = Subject(name: "Spanish")
    let grammar: Subject
    let verbs: Subject
    let emptySubject: Subject
    let biology = Subject(name: "Biology")
    let everyday: Deck, tenses: Deck, regular: Deck, irregular: Deck, cells: Deck, capitals: Deck

    init() {
        grammar = Subject(name: "Grammar", parentID: spanish.id)
        verbs = Subject(name: "Verbs", parentID: grammar.id)
        emptySubject = Subject(name: "Nothing yet", parentID: biology.id)
        func deck(_ name: String, _ n: Int, in s: Subject?) -> Deck {
            Deck(name: name, cards: (1...n).map { Card(front: "\(name) \($0)", back: "b") }, subjectID: s?.id)
        }
        everyday = deck("Everyday Spanish", 10, in: spanish)
        tenses = deck("Tenses", 6, in: grammar)
        regular = deck("Regular verbs", 8, in: verbs)
        irregular = deck("Irregular verbs", 4, in: verbs)
        cells = deck("Cells", 5, in: biology)
        capitals = deck("World Capitals", 7, in: nil)
    }

    var subjects: [Subject] { [spanish, grammar, verbs, biology, emptySubject] }
    var decks: [Deck] { [everyday, tenses, regular, irregular, cells, capitals] }

    func rows(ticked: Set<Deck.ID> = [], playback: [Deck.ID: PlaybackState] = [:]) -> [ReviewChecklist.Row] {
        ReviewChecklist.rows(subjects: subjects, decks: decks, ticked: ticked, playback: playback, now: now)
    }

    func row(_ name: String, in rows: [ReviewChecklist.Row]) -> ReviewChecklist.Row {
        rows.first { $0.name == name }!
    }

    /// `count` cards of `deck` due an hour ago.
    func due(_ deck: Deck, _ count: Int) -> PlaybackState {
        var state = PlaybackState()
        for card in deck.cards.prefix(count) {
            state.reviews[card.id.uuidString] = ReviewState(
                due: now.addingTimeInterval(-3600), interval: 86_400, ease: 2.5, reps: 2, lapses: 0, lastReviewed: now
            )
        }
        return state
    }
}

final class ReviewChecklistTests: XCTestCase {
    private let mix = Mix()

    func testItMirrorsTheLibraryAllThreeLevelsIndented() {
        let rows = mix.rows()
        XCTAssertEqual(rows.map { "\($0.indent) \($0.name)" }, [
            "0 Spanish", "1 Grammar", "2 Verbs", "3 Regular verbs", "3 Irregular verbs", "2 Tenses", "1 Everyday Spanish",
            "0 Biology", "1 Nothing yet", "1 Cells", "0 World Capitals",
        ])
    }

    func testTickingASubjectTicksEveryDeckInsideIt() {
        let rows = mix.rows()
        let ticked = ReviewChecklist.toggled(mix.row("Grammar", in: rows), in: [])
        XCTAssertEqual(ticked, [mix.tenses.id, mix.regular.id, mix.irregular.id], "its sub-subject's decks too")
    }

    func testPartlyTickedParentsShowADash() {
        let ticked: Set<Deck.ID> = [mix.regular.id]
        let rows = mix.rows(ticked: ticked)
        XCTAssertEqual(mix.row("Regular verbs", in: rows).tick, .on)
        XCTAssertEqual(mix.row("Irregular verbs", in: rows).tick, .off)
        XCTAssertEqual(mix.row("Verbs", in: rows).tick, .mixed)
        XCTAssertEqual(mix.row("Grammar", in: rows).tick, .mixed)
        XCTAssertEqual(mix.row("Spanish", in: rows).tick, .mixed)
        XCTAssertEqual(mix.row("Biology", in: rows).tick, .off)
    }

    func testAParentIsTickedOnlyWhenEverythingInsideIs() {
        let all: Set<Deck.ID> = [mix.everyday.id, mix.tenses.id, mix.regular.id, mix.irregular.id]
        let rows = mix.rows(ticked: all)
        XCTAssertEqual(mix.row("Spanish", in: rows).tick, .on)
        XCTAssertEqual(mix.row("Grammar", in: rows).tick, .on)
        XCTAssertEqual(mix.row("World Capitals", in: rows).tick, .off)
    }

    func testClickingATickedOrPartlyTickedParentGoesToAllThenNone() {
        var ticked: Set<Deck.ID> = [mix.regular.id]
        let verbs = mix.row("Verbs", in: mix.rows(ticked: ticked))
        XCTAssertEqual(verbs.tick, .mixed)
        ticked = ReviewChecklist.toggled(verbs, in: ticked)
        XCTAssertEqual(ticked, [mix.regular.id, mix.irregular.id], "a dash ticks the rest")
        let again = mix.row("Verbs", in: mix.rows(ticked: ticked))
        XCTAssertEqual(again.tick, .on)
        XCTAssertEqual(ReviewChecklist.toggled(again, in: ticked), [], "ticked clears them")
    }

    func testUntickingASubjectLeavesOtherDecksAlone() {
        let ticked: Set<Deck.ID> = [mix.regular.id, mix.irregular.id, mix.capitals.id]
        let verbs = mix.row("Verbs", in: mix.rows(ticked: ticked))
        XCTAssertEqual(ReviewChecklist.toggled(verbs, in: ticked), [mix.capitals.id])
    }

    func testASubjectWithNoDecksCannotBeTicked() {
        let rows = mix.rows()
        let empty = mix.row("Nothing yet", in: rows)
        XCTAssertFalse(empty.isEnabled)
        XCTAssertEqual(empty.statusText, "No decks")
        XCTAssertEqual(empty.tick, .off)
        XCTAssertEqual(ReviewChecklist.toggled(empty, in: [mix.cells.id]), [mix.cells.id], "nothing happens")
        XCTAssertTrue(mix.row("Biology", in: rows).isEnabled, "Biology has Cells")
    }

    func testEachRowSaysHowMuchIsDueOrCaughtUp() {
        let rows = mix.rows(playback: [mix.regular.id: mix.due(mix.regular, 3), mix.irregular.id: mix.due(mix.irregular, 2)])
        XCTAssertEqual(mix.row("Regular verbs", in: rows).statusText, "3 due")
        XCTAssertEqual(mix.row("Verbs", in: rows).statusText, "5 due", "everything inside")
        XCTAssertEqual(mix.row("Spanish", in: rows).statusText, "5 due")
        XCTAssertEqual(mix.row("Everyday Spanish", in: rows).statusText, "Caught up")
        XCTAssertEqual(mix.row("World Capitals", in: rows).statusText, "Caught up")
    }

    func testTheSpokenRow() {
        let rows = mix.rows(ticked: [mix.regular.id], playback: [mix.regular.id: mix.due(mix.regular, 3)])
        XCTAssertEqual(mix.row("Verbs", in: rows).accessibilityText, "Verbs, 3 due, partly ticked")
        XCTAssertEqual(mix.row("Regular verbs", in: rows).accessibilityText, "Regular verbs, 3 due, ticked")
        XCTAssertEqual(mix.row("Biology", in: rows).accessibilityText, "Biology, Caught up, not ticked")
    }

    func testTheSummaryAndCountsFollowTheTickedDecks() {
        let playback = [mix.regular.id: mix.due(mix.regular, 3), mix.irregular.id: mix.due(mix.irregular, 2)]
        var setup = ReviewSetup(minutes: 10)
        setup.ticked = ReviewChecklist.toggled(mix.row("Grammar", in: mix.rows()), in: [])
        let summary = ReviewSetupSummary(decks: mix.decks, playback: playback, setup: setup, now: now)
        XCTAssertEqual(summary.tickedDecks, 3)
        XCTAssertEqual(summary.due, 5)
        XCTAssertEqual(summary.new, 6 + 5 + 2, "the rest of Tenses, Regular verbs and Irregular verbs")
        XCTAssertEqual(summary.summaryLine, "3 decks ticked · 5 due · 13 new")
        XCTAssertEqual(summary.countText(for: .everythingShuffled), "18 cards")
    }

    func testTheShortcutChips() {
        var setup = ReviewSetup(startingWith: mix.capitals.id)
        XCTAssertEqual(setup.ticked, [mix.capitals.id], "This deck")
        setup.tickDecks(in: mix.spanish.id, subjects: mix.subjects, decks: mix.decks)
        XCTAssertEqual(setup.ticked, [mix.everyday.id, mix.tenses.id, mix.regular.id, mix.irregular.id], "the current subject")
        setup.tickEverythingDue(decks: mix.decks, playback: [mix.cells.id: mix.due(mix.cells, 1)], now: now)
        XCTAssertEqual(setup.ticked, [mix.cells.id], "Everything due")
        setup.clear()
        XCTAssertTrue(setup.ticked.isEmpty)
    }

    func testTickedIsAlwaysDeckIDsSoMovingADeckAfterwardsChangesNothing() {
        var setup = ReviewSetup(minutes: 10)
        setup.ticked = ReviewChecklist.toggled(mix.row("Verbs", in: mix.rows()), in: [])
        let queue = ReviewQueue.build(deckIDs: setup.ticked, in: mix.decks, playback: [:], options: setup.options, now: now)
        // The regular verbs deck is moved out of the subject (during the sprint, say).
        var moved = mix.decks
        moved[2].subjectID = mix.biology.id
        XCTAssertEqual(setup.ticked, [mix.regular.id, mix.irregular.id])
        XCTAssertEqual(queue.count, 12, "the queue holds both decks' cards")
        XCTAssertEqual(Set(queue.entries.map(\.deckID)), [mix.regular.id, mix.irregular.id])
    }
}

final class ReviewMixSelectionTests: XCTestCase {
    private let mix = Mix()

    func testASubjectResolvesToEveryDeckInsideIncludingSubSubjects() {
        let ids = LibraryOutline.deckIDs(for: [.subject(mix.spanish.id)], subjects: mix.subjects, decks: mix.decks)
        XCTAssertEqual(ids, [mix.everyday.id, mix.tenses.id, mix.regular.id, mix.irregular.id])
    }

    func testDecksAndSubjectsTogetherAreEachCountedOnce() {
        let items: Set<LibraryItem> = [.subject(mix.grammar.id), .deck(mix.regular.id), .deck(mix.capitals.id), .subject(mix.emptySubject.id)]
        let ids = LibraryOutline.deckIDs(for: items, subjects: mix.subjects, decks: mix.decks)
        XCTAssertEqual(ids, [mix.tenses.id, mix.regular.id, mix.irregular.id, mix.capitals.id])
    }

    func testAStaleDeckIsNotCounted() {
        let ids = LibraryOutline.deckIDs(for: [.deck(UUID()), .deck(mix.cells.id)], subjects: mix.subjects, decks: mix.decks)
        XCTAssertEqual(ids, [mix.cells.id])
    }

    func testShiftClickChoosesTheRunBetweenTwoRowsEitherWay() {
        let rows = LibraryOutline.rows(subjects: mix.subjects, decks: mix.decks, expanded: [mix.spanish.id], selection: nil)
        // Visible: Spanish, Grammar, Everyday Spanish, Biology, then World Capitals (headers skipped).
        let down = LibraryOutline.range(from: .subject(mix.spanish.id), to: .deck(mix.everyday.id), in: rows)
        XCTAssertEqual(down, [.subject(mix.spanish.id), .subject(mix.grammar.id), .deck(mix.everyday.id)])
        let up = LibraryOutline.range(from: .deck(mix.capitals.id), to: .deck(mix.everyday.id), in: rows)
        XCTAssertEqual(up, [.deck(mix.everyday.id), .subject(mix.biology.id), .deck(mix.capitals.id)])
        XCTAssertEqual(LibraryOutline.range(from: .deck(mix.cells.id), to: .deck(mix.capitals.id), in: rows), [.deck(mix.capitals.id)], "an anchor that isn't showing")
    }

    func testPickedRowsAreMarkedAndTheOpenPageIsNot() {
        let picked: Set<LibraryItem> = [.subject(mix.spanish.id), .deck(mix.capitals.id)]
        let rows = LibraryOutline.rows(
            subjects: mix.subjects, decks: mix.decks, expanded: [], selection: .subject(mix.biology.id), picked: picked
        )
        for row in rows {
            switch row {
            case .subject(let s): XCTAssertEqual(s.isPicked, s.id == mix.spanish.id, s.name)
            case .deck(let d): XCTAssertEqual(d.isPicked, d.id == mix.capitals.id, d.name)
            case .header: break
            }
        }
        let open = rows.compactMap { row -> String? in if case .subject(let s) = row, s.isSelected { s.name } else { nil } }
        XCTAssertEqual(open, ["Biology"], "choosing rows doesn't change the page that is open")
    }

    func testTheButtonSaysHowManyDecks() {
        XCTAssertEqual(LibraryOutline.reviewTitle(deckCount: 3), "Review 3 decks")
        XCTAssertEqual(LibraryOutline.reviewTitle(deckCount: 1), "Review 1 deck")
    }

    func testTheLastMixIsRememberedAndStaleDecksDropped() {
        let existing = Set(mix.decks.map(\.id))
        let gone = UUID()
        let remembered: Set<Deck.ID> = [mix.regular.id, mix.cells.id, gone]
        // Coming from a deck in the mix: the mix, minus the deleted deck.
        XCTAssertEqual(
            ReviewSetup.startingTicked(remembered: remembered, deckID: mix.regular.id, existing: existing),
            [mix.regular.id, mix.cells.id]
        )
        // Coming from a deck that wasn't in it: just that deck.
        XCTAssertEqual(ReviewSetup.startingTicked(remembered: remembered, deckID: mix.capitals.id, existing: existing), [mix.capitals.id])
        // Nothing remembered: the deck.
        XCTAssertEqual(ReviewSetup.startingTicked(remembered: [], deckID: mix.capitals.id, existing: existing), [mix.capitals.id])
        // No deck given: whatever of the mix still exists.
        XCTAssertEqual(ReviewSetup.startingTicked(remembered: remembered, deckID: nil, existing: existing), [mix.regular.id, mix.cells.id])
        // A fresh launch remembers nothing.
        XCTAssertTrue(ReviewSetup.startingTicked(remembered: [], deckID: nil, existing: existing).isEmpty)
    }

    func testASetupDropsDecksThatNoLongerExist() {
        var setup = ReviewSetup(minutes: 10)
        setup.ticked = [mix.regular.id, UUID()]
        XCTAssertEqual(setup.droppingMissing(from: mix.decks).ticked, [mix.regular.id])
    }
}

@MainActor
final class ReviewMixLayoutTests: XCTestCase {
    func testTheSheetWithATreeStillFitsTheMinimumWindow() throws {
        let mix = Mix()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try DeckStorage(directory: dir).save(Library(subjects: mix.subjects, decks: mix.decks))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = DeckStore(storage: DeckStorage(directory: dir), onSaved: {})
        let sheet = ReviewSetupSheet(
            initialDeckID: mix.regular.id, initialTicked: [mix.regular.id, mix.cells.id], currentSubjectID: mix.spanish.id,
            minutes: 10, onStart: { _ in }, onCancel: {}
        )
        .environmentObject(store)
        .environmentObject(PreviewData.playback())
        .environment(\.accentChoice, .default)
        let renderer = ImageRenderer(content: sheet.frame(width: ReviewSetupSheet.width, height: 560).preferredColorScheme(.dark))
        renderer.scale = 1
        XCTAssertNotNil(renderer.cgImage)
        let size = NSHostingView(rootView: sheet).fittingSize
        XCTAssertLessThan(size.width, MainWindowView.minimumSize.width)
        XCTAssertLessThan(size.height, 680)
    }
}

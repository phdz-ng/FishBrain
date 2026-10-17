import AppKit
import SwiftUI
import XCTest

/// Subjects in the sidebar and the subject page (FLAS-63): the outline, the New menu and the tile maths.
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

private func makeDeck(_ name: String, _ count: Int, in subject: Subject? = nil) -> Deck {
    Deck(name: name, cards: (1...count).map { Card(front: "\(name) \($0)", back: "b") }, subjectID: subject?.id)
}

private func review(due: TimeInterval, reps: Int = 2) -> ReviewState {
    ReviewState(due: now.addingTimeInterval(due), interval: max(abs(due), day), ease: 2.5, reps: reps, lapses: 0, lastReviewed: now)
}

/// Spanish > Grammar > Verbs, with decks at each level, plus Biology and loose decks.
private struct Library3 {
    let spanish = Subject(name: "Spanish")
    let grammar: Subject
    let verbs: Subject
    let biology = Subject(name: "Biology")
    let everyday: Deck, grammarDeck: Deck, regular: Deck, irregular: Deck, cells: Deck, capitals: Deck

    init() {
        grammar = Subject(name: "Grammar", parentID: spanish.id)
        verbs = Subject(name: "Verbs", parentID: grammar.id)
        everyday = makeDeck("Everyday Spanish", 48, in: spanish)
        grammarDeck = makeDeck("Tenses", 10, in: grammar)
        regular = makeDeck("Regular verbs", 30, in: verbs)
        irregular = makeDeck("Irregular verbs", 22, in: verbs)
        cells = makeDeck("Cells", 40, in: biology)
        capitals = makeDeck("World Capitals", 60)
    }

    var subjects: [Subject] { [spanish, grammar, verbs, biology] }
    var decks: [Deck] { [everyday, grammarDeck, regular, irregular, cells, capitals] }

    func rows(expanded: Set<Subject.ID> = [], selection: LibrarySelection? = nil, playback: [Deck.ID: PlaybackState] = [:]) -> [LibraryOutline.Row] {
        LibraryOutline.rows(subjects: subjects, decks: decks, expanded: expanded, selection: selection, playback: playback, now: now)
    }
}

private func names(_ rows: [LibraryOutline.Row]) -> [String] {
    rows.map { row in
        switch row {
        case .header(let header): "# \(header.rawValue)"
        case .subject(let subject): "S\(subject.indent) \(subject.name)"
        case .deck(let deck): "D\(deck.indent) \(deck.name)"
        }
    }
}

final class LibraryOutlineTests: XCTestCase {
    private let lib = Library3()

    func testALibraryOfLooseDecksIsAsItWasWithNoSubjectsSection() {
        let decks = [makeDeck("a", 1), makeDeck("b", 2)]
        let rows = LibraryOutline.rows(subjects: [], decks: decks, expanded: [], selection: nil)
        XCTAssertEqual(names(rows), ["# Decks", "D0 a", "D0 b"])
    }

    func testCollapsedSubjectsShowOnlyThemselvesWithEverythingInsideCounted() {
        let rows = lib.rows()
        XCTAssertEqual(names(rows), ["# Subjects", "S0 Spanish", "S0 Biology", "# Decks", "D0 World Capitals"])
        guard case .subject(let spanish) = rows[1] else { return XCTFail() }
        XCTAssertEqual(spanish.cardCount, 48 + 10 + 30 + 22, "its decks, Grammar's and Verbs'")
        XCTAssertTrue(spanish.isExpandable)
        XCTAssertFalse(spanish.isExpanded)
        XCTAssertFalse(spanish.opensPage)
    }

    func testExpandedSubjectShowsItsSubSubjectsThenItsDecksOneIndentIn() {
        let rows = lib.rows(expanded: [lib.spanish.id])
        XCTAssertEqual(names(rows), [
            "# Subjects", "S0 Spanish", "S1 Grammar", "D1 Everyday Spanish", "S0 Biology", "# Decks", "D0 World Capitals",
        ])
        guard case .subject(let grammar) = rows[2] else { return XCTFail() }
        XCTAssertTrue(grammar.opensPage, "a sub-subject has the trailing ›")
        XCTAssertFalse(grammar.isExpandable, "and doesn't expand in the sidebar")
        XCTAssertEqual(grammar.cardCount, 62)
    }

    func testTheSidebarNeverGoesMoreThanOneIndentDeep() {
        let everything = Set(lib.subjects.map(\.id))
        for row in lib.rows(expanded: everything) {
            switch row {
            case .subject(let subject): XCTAssertLessThanOrEqual(subject.indent, 1, subject.name)
            case .deck(let deck): XCTAssertLessThanOrEqual(deck.indent, 1, deck.name)
            case .header: break
            }
        }
        // The third level has no row of its own, and nor do the decks in the second.
        let shown = names(lib.rows(expanded: everything))
        XCTAssertFalse(shown.contains { $0.contains("Verbs") })
        XCTAssertFalse(shown.contains { $0.contains("Tenses") })
    }

    func testTheNearestVisibleAncestorIsMarkedForADeeperPage() {
        // Verbs is the third level: Grammar is the nearest row that can show for it.
        let open = lib.rows(expanded: [lib.spanish.id], selection: .subject(lib.verbs.id))
        XCTAssertEqual(markedNames(open), ["Grammar"])
        XCTAssertEqual(selectedNames(open), [])
        // With Spanish collapsed, Spanish is the nearest.
        let collapsed = lib.rows(expanded: [], selection: .subject(lib.verbs.id))
        XCTAssertEqual(markedNames(collapsed), ["Spanish"])
        // A deck inside Verbs marks the same way.
        let deck = lib.rows(expanded: [lib.spanish.id], selection: .deck(lib.regular.id))
        XCTAssertEqual(markedNames(deck), ["Grammar"])
    }

    func testAVisibleRowIsSelectedNotMarked() {
        let rows = lib.rows(expanded: [lib.spanish.id], selection: .subject(lib.grammar.id))
        XCTAssertEqual(selectedNames(rows), ["Grammar"])
        XCTAssertEqual(markedNames(rows), [])
        let deck = lib.rows(expanded: [lib.spanish.id], selection: .deck(lib.everyday.id))
        XCTAssertEqual(deck.compactMap { if case .deck(let d) = $0, d.isSelected { d.name } else { nil } }, ["Everyday Spanish"])
        XCTAssertEqual(markedNames(deck), [])
    }

    private func markedNames(_ rows: [LibraryOutline.Row]) -> [String] {
        rows.compactMap { if case .subject(let s) = $0, s.isMarked { s.name } else { nil } }
    }

    private func selectedNames(_ rows: [LibraryOutline.Row]) -> [String] {
        rows.compactMap { if case .subject(let s) = $0, s.isSelected { s.name } else { nil } }
    }

    func testDueCountsAndTheSpokenRow() {
        var regular = PlaybackState(), irregular = PlaybackState()
        for card in lib.regular.cards.prefix(3) { regular.reviews[card.id.uuidString] = review(due: -3600) }
        for card in lib.irregular.cards.prefix(2) { irregular.reviews[card.id.uuidString] = review(due: -3600) }
        let rows = lib.rows(expanded: [lib.spanish.id], playback: [lib.regular.id: regular, lib.irregular.id: irregular])
        guard case .subject(let grammar) = rows[2] else { return XCTFail() }
        XCTAssertEqual(grammar.dueCount, 5, "Verbs' two decks, which Grammar holds")
        XCTAssertEqual(grammar.accessibilityText, "Grammar, subject, 62 cards, 5 due")

        XCTAssertEqual(
            LibraryOutline.SubjectRow(
                id: UUID(), name: "Grammar", color: .accent, indent: 1, cardCount: 52, dueCount: 5, isExpandable: false,
                isExpanded: false, opensPage: true, isSelected: false, isMarked: false
            ).accessibilityText,
            "Grammar, subject, 52 cards, 5 due", "the ticket's wording"
        )
    }

    func testADeckInACollapsedSubjectIsRevealedByADeepLinkOrSearchResult() {
        let none: Set<Subject.ID> = []
        XCTAssertEqual(LibraryOutline.expanded(none, revealing: .deck(lib.everyday.id), subjects: lib.subjects, decks: lib.decks), [lib.spanish.id])
        XCTAssertEqual(LibraryOutline.expanded(none, revealing: .deck(lib.regular.id), subjects: lib.subjects, decks: lib.decks), [lib.spanish.id], "deep inside: the top-level one opens")
        XCTAssertEqual(LibraryOutline.expanded(none, revealing: .subject(lib.verbs.id), subjects: lib.subjects, decks: lib.decks), [lib.spanish.id])
        XCTAssertEqual(LibraryOutline.expanded(none, revealing: .deck(lib.capitals.id), subjects: lib.subjects, decks: lib.decks), none, "a loose deck needs nothing")
        XCTAssertEqual(LibraryOutline.expanded(none, revealing: .subject(lib.spanish.id), subjects: lib.subjects, decks: lib.decks), none, "a top-level subject is already a row")
        XCTAssertEqual(LibraryOutline.expanded([lib.biology.id], revealing: .deck(lib.everyday.id), subjects: lib.subjects, decks: lib.decks), [lib.biology.id, lib.spanish.id])
    }

    func testArrowKeysMoveThroughVisibleRowsAndStopAtTheEnds() {
        let rows = lib.rows(expanded: [lib.spanish.id])
        // Subjects, Grammar, Everyday Spanish, Biology, World Capitals: the headers are skipped.
        XCTAssertEqual(LibraryOutline.neighbor(of: nil, in: rows, step: 1), .subject(lib.spanish.id))
        XCTAssertEqual(LibraryOutline.neighbor(of: nil, in: rows, step: -1), .deck(lib.capitals.id))
        XCTAssertEqual(LibraryOutline.neighbor(of: .subject(lib.spanish.id), in: rows, step: 1), .subject(lib.grammar.id))
        XCTAssertEqual(LibraryOutline.neighbor(of: .subject(lib.grammar.id), in: rows, step: 1), .deck(lib.everyday.id))
        XCTAssertEqual(LibraryOutline.neighbor(of: .deck(lib.everyday.id), in: rows, step: 1), .subject(lib.biology.id))
        XCTAssertEqual(LibraryOutline.neighbor(of: .deck(lib.capitals.id), in: rows, step: 1), .deck(lib.capitals.id), "stops at the end")
        XCTAssertEqual(LibraryOutline.neighbor(of: .subject(lib.spanish.id), in: rows, step: -1), .subject(lib.spanish.id))
        XCTAssertNil(LibraryOutline.neighbor(of: nil, in: [], step: 1))
    }

    func testADeckOfAMissingSubjectShowsAsLoose() {
        let orphan = Deck(name: "Orphan", cards: [], subjectID: UUID())
        let rows = LibraryOutline.rows(subjects: [], decks: [orphan], expanded: [], selection: nil)
        XCTAssertEqual(names(rows), ["# Decks", "D0 Orphan"])
    }
}

final class NewMenuTests: XCTestCase {
    private let lib = Library3()
    private var tree: SubjectTree { SubjectTree(lib.subjects) }

    func testWithNoSubjectOpenItIsNewDeckAndNewSubject() {
        let items = NewMenu.items(in: nil, tree: tree)
        XCTAssertEqual(items.map(\.title), ["New Deck", "New Subject"])
        XCTAssertEqual(items.map(\.shortcut), ["⌘N", "⇧⌘N"])
        XCTAssertTrue(items.allSatisfy(\.isEnabled))
    }

    func testInsideASubjectItAddsTheInVersions() {
        for subject in [lib.spanish, lib.grammar] {
            let items = NewMenu.items(in: subject.id, tree: tree)
            XCTAssertEqual(items.map(\.title), ["New Deck", "New Subject", "New Deck in \(subject.name)", "New Subject in \(subject.name)"])
            XCTAssertTrue(items.allSatisfy(\.isEnabled), subject.name)
        }
    }

    func testAtTheThirdLevelNewSubjectIsOffAndNamesTheParent() {
        let items = NewMenu.items(in: lib.verbs.id, tree: tree)
        let deckIn = items.first { $0.action == .newDeckIn(lib.verbs.id) }
        let subjectIn = items.first { $0.action == .newSubjectIn(lib.verbs.id) }
        XCTAssertEqual(deckIn?.isEnabled, true)
        XCTAssertEqual(subjectIn?.isEnabled, false)
        XCTAssertEqual(subjectIn?.disabledReason, "Three levels is the most. Pick New Subject in Grammar instead.")
        XCTAssertEqual(items.first { $0.action == .newSubject }?.isEnabled, true, "a new top-level subject is always fine")
    }
}

final class StatusBreakdownTests: XCTestCase {
    func testBucketsFollowCardStatus() {
        let deck = makeDeck("d", 9)
        var state = PlaybackState()
        let c = deck.cards
        // 0 new, 1 new; 2 learning (10 min); 3 due learning; 4 due graduated; 5 young (4 days); 6 young (20 days);
        // 7 mastered (21 days); 8 mastered (90 days).
        state.reviews[c[2].id.uuidString] = review(due: 600, reps: 0)
        state.reviews[c[3].id.uuidString] = review(due: -60, reps: 0)
        state.reviews[c[4].id.uuidString] = review(due: -day, reps: 3)
        state.reviews[c[5].id.uuidString] = review(due: 4 * day, reps: 2)
        state.reviews[c[6].id.uuidString] = review(due: 20 * day, reps: 2)
        state.reviews[c[7].id.uuidString] = review(due: 21 * day, reps: 4)
        state.reviews[c[8].id.uuidString] = review(due: 90 * day, reps: 4)

        let b = StatusBreakdown(cards: c, state: state, now: now)
        XCTAssertEqual(b.new, 2)
        XCTAssertEqual(b.learning, 2, "one waiting, one due")
        XCTAssertEqual(b.young, 3, "the due graduated card and the two coming back within 21 days")
        XCTAssertEqual(b.mastered, 2)
        XCTAssertEqual(b.due, 2)
        XCTAssertEqual(b.total, 9, "every card is in exactly one bar segment")
    }

    func testTheTileCountsMatchTheCardStatuses() {
        let deck = makeDeck("d", 40)
        var state = PlaybackState()
        for (i, card) in deck.cards.enumerated() {
            switch i % 4 {
            case 0: state.reviews[card.id.uuidString] = review(due: Double(30 + i) * day, reps: 4)
            case 1: state.reviews[card.id.uuidString] = review(due: -Double(i) * 60, reps: 2)
            case 2: state.reviews[card.id.uuidString] = review(due: Double(i) * day / 4, reps: 2)
            default: break
            }
        }
        let b = StatusBreakdown(cards: deck.cards, state: state, now: now)
        let statuses = deck.cards.map { CardStatus(state.review(for: $0.id), at: now) }
        XCTAssertEqual(b.due, statuses.filter { $0 == .dueNow }.count)
        XCTAssertEqual(b.new, statuses.filter { $0 == .new }.count)
        XCTAssertEqual(b.mastered, statuses.filter { $0.tone == .mastered }.count)
        XCTAssertEqual(b.due, state.dueCount(in: deck, at: now), "the same due count the deck header uses")
        XCTAssertEqual(b.learning + b.young + b.mastered + b.new, 40)
    }

    func testTheBarsPartsAddUpToOne() {
        var b = StatusBreakdown()
        XCTAssertTrue(b.segments.isEmpty)
        b = StatusBreakdown(cards: makeDeck("d", 4).cards, state: nil, now: now)
        XCTAssertEqual(b.segments.map(\.fraction).reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(b.segments.first { $0.segment == .new }?.fraction, 1)
    }

    func testTheLineUnderTheBar() {
        var b = StatusBreakdown()
        XCTAssertEqual(b.summaryText, "No cards yet")
        b.due = 9; b.mastered = 22; b.new = 12; b.young = 5
        XCTAssertEqual(b.summaryText, "9 due · 22 mastered · 12 new")
        b.due = 0; b.mastered = 4
        XCTAssertEqual(b.summaryText, "Caught up · 4 mastered · 12 new")
        b.mastered = 0
        XCTAssertEqual(b.summaryText, "Caught up · 12 new")
    }
}

final class SubjectSummaryTests: XCTestCase {
    private let lib = Library3()

    private func summary(_ subject: Subject, playback: [Deck.ID: PlaybackState] = [:]) -> SubjectSummary {
        SubjectSummary(subject: subject.id, tree: SubjectTree(lib.subjects), decks: lib.decks, playback: playback, now: now)
    }

    func testThePageSubtitleForASubjectWithSubjectsAndDecks() {
        var state = PlaybackState()
        for card in lib.everyday.cards.prefix(14) { state.reviews[card.id.uuidString] = review(due: -60) }
        let s = summary(lib.spanish, playback: [lib.everyday.id: state])
        XCTAssertEqual(s.subjectCount, 1)
        XCTAssertEqual(s.deckCount, 1)
        XCTAssertEqual(s.pageSubtitle, "1 subject and 1 deck inside · 110 cards in all, 14 due")
    }

    func testThePageSubtitleForASubjectWithOnlyDecks() {
        var state = PlaybackState()
        for card in lib.regular.cards.prefix(5) { state.reviews[card.id.uuidString] = review(due: -60) }
        XCTAssertEqual(summary(lib.verbs, playback: [lib.regular.id: state]).pageSubtitle, "2 decks · 52 cards, 5 due")
        XCTAssertEqual(summary(lib.verbs).pageSubtitle, "2 decks · 52 cards")
    }

    func testAnEmptySubject() {
        let empty = Subject(name: "Empty")
        let s = SubjectSummary(subject: empty.id, tree: SubjectTree([empty]), decks: [], playback: [:], now: now)
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.pageSubtitle, "Nothing inside yet")
        XCTAssertEqual(s.tileSubtitle, "0 cards")
    }

    func testTheTileCountsEverythingInsideAtAnyDepth() {
        XCTAssertEqual(summary(lib.grammar).tileSubtitle, "1 subject · 3 decks · 62 cards")
        XCTAssertEqual(summary(lib.verbs).tileSubtitle, "2 decks · 52 cards")
        XCTAssertEqual(summary(lib.spanish).tileSubtitle, "2 subjects · 4 decks · 110 cards")
    }

    func testTheSpokenTile() {
        var state = PlaybackState()
        for card in lib.regular.cards.prefix(5) { state.reviews[card.id.uuidString] = review(due: -60) }
        let s = summary(lib.verbs, playback: [lib.regular.id: state])
        XCTAssertEqual(s.accessibilityText(name: "Grammar"), "Grammar, subject, 52 cards, 5 due")
    }
}

@MainActor
final class SubjectExpansionTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "FishBrainTests-\(UUID().uuidString)")!
        return defaults
    }

    func testExpandedStateIsRemembered() {
        let defaults = makeDefaults()
        let a = UUID(), b = UUID()
        let first = SubjectExpansion(defaults: defaults)
        XCTAssertTrue(first.ids.isEmpty)
        first.toggle(a)
        first.set(b, expanded: true)
        first.toggle(b)
        XCTAssertEqual(first.ids, [a])
        XCTAssertEqual(SubjectExpansion(defaults: defaults).ids, [a], "after a relaunch")
    }

    func testRevealOpensWhatTheSelectionNeeds() {
        let lib = Library3()
        let expansion = SubjectExpansion(defaults: makeDefaults())
        expansion.reveal(.deck(lib.regular.id), subjects: lib.subjects, decks: lib.decks)
        XCTAssertEqual(expansion.ids, [lib.spanish.id])
        expansion.reveal(.deck(lib.capitals.id), subjects: lib.subjects, decks: lib.decks)
        XCTAssertEqual(expansion.ids, [lib.spanish.id])
    }
}

@MainActor
final class SubjectScreensLayoutTests: XCTestCase {
    private func store(_ lib: Library3) throws -> DeckStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try DeckStorage(directory: dir).save(Library(subjects: lib.subjects, decks: lib.decks))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return DeckStore(storage: DeckStorage(directory: dir), onSaved: {})
    }

    private func render<V: View>(_ view: V, size: CGSize) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        renderer.scale = 1
        XCTAssertNotNil(renderer.cgImage)
    }

    func testTheMainWindowLaysOutAtMinimumSizeWithSubjects() throws {
        let lib = Library3()
        let view = MainWindowView()
            .environmentObject(try store(lib))
            .environmentObject(PreviewData.playback())
            .environmentObject(PreviewData.study())
            .environmentObject(PreviewData.runHistory())
            .environmentObject(PreviewData.studyClock())
            .environmentObject(PreviewData.settings())
            .environmentObject(PreviewData.composer())
            .environment(\.accentChoice, .default)
        render(view, size: MainWindowView.minimumSize)
    }

    func testASubjectPageAndAnEmptyOneLayOut() throws {
        let lib = Library3()
        let empty = Subject(name: "Empty")
        let store = try store(lib)
        store.addSubject(name: "Empty")
        for subject in [lib.spanish, lib.verbs, empty] {
            let page = SubjectPageView(
                subject: subject, isRenaming: .constant(false), onOpenSubject: { _ in }, onOpenDeck: { _ in },
                onNewDeck: { _ in }, onNewSubject: { _ in }, onLearn: { _ in }, onReview: { _ in }, onRename: { _ in }, onSetColor: { _ in }
            )
            .environmentObject(store)
            .environmentObject(PreviewData.playback())
            .environment(\.accentChoice, .default)
            render(page, size: CGSize(width: 680, height: 420))
        }
    }

    func testTheSidebarRowsRender() {
        let lib = Library3()
        let rows = lib.rows(expanded: [lib.spanish.id], selection: .subject(lib.verbs.id))
        for row in rows {
            if case .subject(let subject) = row {
                render(SidebarSubjectRow(row: subject, onSelect: {}, onToggle: {}).environment(\.accentChoice, .default), size: CGSize(width: 228, height: 40))
            }
        }
    }
}

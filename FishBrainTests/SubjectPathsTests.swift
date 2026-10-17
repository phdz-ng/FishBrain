import SwiftUI
import XCTest

/// The subject path wherever decks are listed (FLAS-65): search, the notch's picker, the widget's deck choice.
private struct Verbs {
    let spanish = Subject(name: "Spanish")
    let grammar: Subject
    let spanishVerbs: Subject
    let french = Subject(name: "French")
    let frenchVerbs: Subject
    let regular: Deck, irregular: Deck, spanishDeck: Deck, frenchDeck: Deck, loose: Deck

    init() {
        grammar = Subject(name: "Grammar", parentID: spanish.id)
        spanishVerbs = Subject(name: "Verbs", parentID: grammar.id)
        frenchVerbs = Subject(name: "Verbs", parentID: french.id)
        func deck(_ name: String, in subject: Subject?, front: String = "hablar") -> Deck {
            Deck(name: name, cards: [Card(front: front, back: "to speak")], subjectID: subject?.id)
        }
        regular = deck("Regular verbs", in: spanishVerbs)
        irregular = deck("Irregular verbs", in: spanishVerbs)
        spanishDeck = deck("Verbs", in: spanishVerbs, front: "ser")
        frenchDeck = deck("Verbs", in: frenchVerbs, front: "être")
        loose = deck("World Capitals", in: nil, front: "Paris")
    }

    var subjects: [Subject] { [spanish, grammar, spanishVerbs, french, frenchVerbs] }
    var decks: [Deck] { [regular, irregular, spanishDeck, frenchDeck, loose] }
}

final class SubjectPathFormatTests: XCTestCase {
    private let v = Verbs()

    func testNoLevelsOneTwoAndThree() {
        XCTAssertNil(SubjectPath.text(of: nil, in: v.subjects), "a loose deck has no path")
        XCTAssertNil(SubjectPath.text(of: UUID(), in: v.subjects), "nor one in a subject that isn't there")
        XCTAssertEqual(SubjectPath.text(of: v.spanish.id, in: v.subjects), "Spanish")
        XCTAssertEqual(SubjectPath.text(of: v.grammar.id, in: v.subjects), "Spanish › Grammar")
        XCTAssertEqual(SubjectPath.text(of: v.spanishVerbs.id, in: v.subjects), "Spanish › Grammar › Verbs")
    }

    func testADecksPathEndsWithItsOwnName() {
        XCTAssertEqual(SubjectPath.text(for: v.regular, in: v.subjects), "Spanish › Grammar › Verbs › Regular verbs")
        XCTAssertEqual(SubjectPath.text(for: v.loose, in: v.subjects), "World Capitals")
        let atTheTop = Deck(name: "Notes", subjectID: v.spanish.id)
        XCTAssertEqual(SubjectPath.text(for: atTheTop, in: v.subjects), "Spanish › Notes")
    }

    func testTwoDecksCalledTheSameAreToldApart() {
        XCTAssertNotEqual(SubjectPath.text(for: v.spanishDeck, in: v.subjects), SubjectPath.text(for: v.frenchDeck, in: v.subjects))
        XCTAssertEqual(SubjectPath.text(for: v.frenchDeck, in: v.subjects), "French › Verbs › Verbs")
    }

    func testLongNamesAreShortenedInTheMiddle() {
        let name = "Intermediate Spanish verbs and tenses"
        let shortened = SubjectPath.middleTruncated(name)
        XCTAssertEqual(shortened.count, SubjectPath.maxNameLength)
        XCTAssertEqual(shortened, "Intermediate… and tenses")
        XCTAssertTrue(shortened.contains("…"))
        XCTAssertEqual(SubjectPath.middleTruncated("Short"), "Short")
        XCTAssertEqual(SubjectPath.middleTruncated(String(repeating: "a", count: 24)), String(repeating: "a", count: 24), "exactly the limit is left alone")
        XCTAssertEqual(SubjectPath.middleTruncated("abcdefghij", to: 5), "ab…ij")
        XCTAssertEqual(SubjectPath.middleTruncated("abcdef", to: 2), "abcdef", "no room to shorten sensibly")
    }

    func testEveryPartOfAPathIsShortenedNotJustTheLast() {
        let long = Subject(name: "A very long subject name indeed")
        let inner = Subject(name: "Another extremely long inner subject", parentID: long.id)
        let deck = Deck(name: "An equally long deck name for testing", subjectID: inner.id)
        let text = SubjectPath.text(for: deck, in: [long, inner])
        for part in text.components(separatedBy: SubjectPath.separator) {
            XCTAssertLessThanOrEqual(part.count, SubjectPath.maxNameLength, part)
        }
        XCTAssertEqual(text.components(separatedBy: SubjectPath.separator).count, 3)
    }
}

final class SearchResultPathTests: XCTestCase {
    private let v = Verbs()

    func testResultsInASubjectCarryTheirPath() {
        let results = CardSearch.search("hablar", in: v.decks, subjects: v.subjects)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map(\.deckPath), [
            "Spanish › Grammar › Verbs › Regular verbs", "Spanish › Grammar › Verbs › Irregular verbs",
        ])
        XCTAssertEqual(results.map(\.deckName), ["Regular verbs", "Irregular verbs"], "the name is still there")
    }

    func testALooseDecksResultHasNoPath() {
        let result = CardSearch.search("Paris", in: v.decks, subjects: v.subjects).first
        XCTAssertEqual(result?.deckName, "World Capitals")
        XCTAssertNil(result?.deckPath)
    }

    func testSearchWithoutSubjectsBehavesAsBefore() {
        let results = CardSearch.search("hablar", in: v.decks)
        XCTAssertEqual(results.map(\.deckName), ["Regular verbs", "Irregular verbs"])
        XCTAssertEqual(results.map(\.deckPath), ["Regular verbs", "Irregular verbs"].map { name in
            SubjectPath.text(for: v.decks.first { $0.name == name }!, in: [])
        }, "an unknown subject reads as the deck's name alone")
    }

    func testTwoDecksCalledVerbsGiveDifferentLines() {
        let ser = CardSearch.search("ser", in: v.decks, subjects: v.subjects)
        let etre = CardSearch.search("être", in: v.decks, subjects: v.subjects)
        XCTAssertEqual(ser.first?.deckName, etre.first?.deckName, "the same name")
        XCTAssertNotEqual(ser.first?.deckPath, etre.first?.deckPath)
    }

    func testSelectingAResultOpensItsSubjectsInTheSidebar() {
        let result = CardSearch.search("être", in: v.decks, subjects: v.subjects)[0]
        let expanded = LibraryOutline.expanded([], revealing: .deck(result.deckID), subjects: v.subjects, decks: v.decks)
        XCTAssertEqual(expanded, [v.french.id])
    }

    func testTheDeepLinkIntoACollapsedSubjectOpensIt() throws {
        let url = DeepLink.deck(v.regular.id)
        let id = try XCTUnwrap(DeepLink.deckID(from: url))
        XCTAssertEqual(id, v.regular.id)
        let expanded = LibraryOutline.expanded([], revealing: .deck(id), subjects: v.subjects, decks: v.decks)
        XCTAssertEqual(expanded, [v.spanish.id], "the top-level subject that holds it")
        // And with that open, the deck's own row isn't deeper than the sidebar shows, so Grammar is marked.
        let rows = LibraryOutline.rows(subjects: v.subjects, decks: v.decks, expanded: expanded, selection: .deck(id))
        let marked = rows.compactMap { row -> String? in
            if case .subject(let s) = row, s.isMarked { return s.name }
            return nil
        }
        XCTAssertEqual(marked, ["Grammar"])
    }
}

final class DeckPickerSectionTests: XCTestCase {
    private let v = Verbs()

    func testWithNoSubjectsTheListIsFlat() {
        let sections = DeckPicker.sections(decks: v.decks, subjects: [])
        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
        XCTAssertEqual(sections[0].decks.map(\.id), v.decks.map(\.id))
        XCTAssertTrue(DeckPicker.sections(decks: [], subjects: []).isEmpty)
    }

    func testDecksAreGroupedUnderTheirSubjectPathWithLooseOnesLast() {
        let sections = DeckPicker.sections(decks: v.decks, subjects: v.subjects)
        XCTAssertEqual(sections.map(\.title), ["Spanish › Grammar › Verbs", "French › Verbs", "Decks"])
        XCTAssertEqual(sections[0].decks.map(\.name), ["Regular verbs", "Irregular verbs", "Verbs"])
        XCTAssertEqual(sections[1].decks.map(\.name), ["Verbs"])
        XCTAssertEqual(sections[2].decks.map(\.name), ["World Capitals"])
    }

    func testSubjectsHoldingNoDeckAreLeftOut() {
        let titles = DeckPicker.sections(decks: v.decks, subjects: v.subjects).compactMap(\.title)
        XCTAssertFalse(titles.contains("Spanish"), "Spanish holds no deck directly")
        XCTAssertFalse(titles.contains("Spanish › Grammar"))
    }

    func testEveryDeckAppearsExactlyOnce() {
        let listed = DeckPicker.sections(decks: v.decks, subjects: v.subjects).flatMap(\.decks).map(\.id)
        XCTAssertEqual(Set(listed), Set(v.decks.map(\.id)))
        XCTAssertEqual(listed.count, v.decks.count)
    }

    func testADeckOfAMissingSubjectIsListedAsLoose() {
        let orphan = Deck(name: "Orphan", subjectID: UUID())
        let sections = DeckPicker.sections(decks: [orphan] + v.decks, subjects: v.subjects)
        XCTAssertEqual(sections.last?.title, "Decks")
        XCTAssertEqual(sections.last?.decks.first?.name, "Orphan")
    }

    func testADeletedChoiceStillFallsBackToTheFirstDeck() {
        let remaining = v.decks.filter { $0.id != v.frenchDeck.id }
        XCTAssertEqual(DeckSelection.resolve(v.frenchDeck.id, in: remaining)?.id, remaining.first?.id)
    }
}

final class WidgetDeckChoicePathTests: XCTestCase {
    private let v = Verbs()

    func testDecksWithTheSameNameGetDistinctSubtitles() {
        let entities = DeckEntity.all(in: v.decks, subjects: v.subjects)
        let verbs = entities.filter { $0.name == "Verbs" }
        XCTAssertEqual(verbs.count, 2)
        XCTAssertEqual(Set(verbs.compactMap(\.subjectPath)), ["Spanish › Grammar › Verbs", "French › Verbs"])
        XCTAssertNil(entities.first { $0.name == "World Capitals" }?.subjectPath, "a loose deck has no subtitle")
    }

    func testTheEntityIsStillTheDecksIDSoOldConfigurationsKeepWorking() {
        let entities = DeckEntity.all(in: v.decks, subjects: v.subjects)
        XCTAssertEqual(entities.map(\.id), v.decks.map(\.id))
        // A stored choice is a deck id, however the deck was renamed or filed since.
        let stored = [v.frenchDeck.id]
        let found = DeckEntity.matching(stored, in: v.decks, subjects: v.subjects)
        XCTAssertEqual(found.map(\.id), stored)
        XCTAssertEqual(found.first?.subjectPath, "French › Verbs")
    }

    func testTheWidgetsHeaderStillShowsTheDeckNameOnly() {
        let entry = FishBrainEntry.make(decks: v.decks, playback: [:], accent: .indigo, at: Date(timeIntervalSince1970: 0), deckID: v.frenchDeck.id)
        XCTAssertEqual(entry.showing?.deckName, "Verbs")
    }

    func testTheOldTwoArgumentFormsStillWork() {
        XCTAssertEqual(DeckEntity.all(in: v.decks).count, 5)
        XCTAssertNil(DeckEntity(id: UUID(), name: "X").subjectPath)
        XCTAssertNil(DeckEntity(v.regular).subjectPath, "without the subjects there is no path to give")
    }
}

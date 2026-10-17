import XCTest

final class AnkiExportTests: XCTestCase {
    private let spanish = Subject(name: "Spanish")
    private lazy var grammar = Subject(name: "Grammar", parentID: spanish.id)
    private lazy var verbs = Subject(name: "Verbs", parentID: grammar.id)
    private lazy var subjects = [spanish, grammar, verbs]

    private let picture = AnkiFixture.png()

    private lazy var regular = Deck(
        name: "Regular",
        cards: [
            Card(front: "hablar", back: "to speak"),
            Card(front: "line one\nline two", back: "a < b & c > d"),
        ],
        subjectID: verbs.id
    )
    private lazy var phrases = Deck(
        name: "Phrases", cards: [Card(front: "hola", back: "hello")], subjectID: spanish.id
    )
    private lazy var loose = Deck(name: "Loose", cards: [Card(front: "café", back: "coffee")])
    private lazy var empty = Deck(name: "Empty", subjectID: spanish.id)
    private lazy var decks = [regular, phrases, loose, empty]

    private func export(
        _ target: ExportTarget, excluded: Set<Deck.ID> = [], decks custom: [Deck]? = nil,
        picture load: @escaping (CardImage) -> Data? = { _ in nil }
    ) throws -> (AnkiExport.Result, AnkiPackage) {
        var draft = ExportDraft(target: target)
        draft.format = .anki
        draft.excluded = excluded
        let result = try AnkiExport.package(
            for: draft, subjects: subjects, decks: custom ?? decks, loadPicture: load,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        return (result, try AnkiPackage(data: result.data))
    }

    // MARK: Structure

    func testASubjectBecomesNestedDecksFromTheExportedSubjectDown() throws {
        let (result, package) = try export(.subject(spanish.id))
        let names = Set(package.decks.values)
        XCTAssertTrue(names.contains("Spanish::Grammar::Verbs::Regular"))
        XCTAssertTrue(names.contains("Spanish::Phrases"))
        // Parents are written too, so Anki doesn't have to invent them.
        XCTAssertTrue(names.isSuperset(of: ["Spanish", "Spanish::Grammar", "Spanish::Grammar::Verbs"]))
        XCTAssertTrue(names.contains("Default"))
        XCTAssertEqual(result.cardCount, 3)
        XCTAssertEqual(result.deckCount, 2, "the empty deck isn't written")
        XCTAssertFalse(names.contains("Spanish::Empty"))
    }

    func testTheLibraryStartsPathsAtTheTopAndLooseDecksAreJustTheirName() throws {
        let (result, package) = try export(.library)
        XCTAssertEqual(result.cardCount, 4)
        XCTAssertTrue(package.decks.values.contains("Spanish::Grammar::Verbs::Regular"))
        XCTAssertTrue(package.decks.values.contains("Spanish::Phrases"))
        XCTAssertTrue(package.decks.values.contains("Loose"))
    }

    func testAnInnerSubjectStartsItsPathsAtItself() throws {
        let (_, package) = try export(.subject(grammar.id))
        XCTAssertTrue(package.decks.values.contains("Grammar::Verbs::Regular"))
        XCTAssertFalse(package.decks.values.contains { $0.hasPrefix("Spanish") })
    }

    func testOneDeckIsJustItsName() throws {
        let (result, package) = try export(.deck(regular.id))
        XCTAssertTrue(package.decks.values.contains("Regular"))
        XCTAssertEqual(result.deckCount, 1)
        XCTAssertEqual(result.cardCount, 2)
    }

    func testUntickedDecksAreLeftOut() throws {
        let (result, package) = try export(.library, excluded: [regular.id])
        XCTAssertEqual(result.cardCount, 2)
        XCTAssertFalse(package.notes.contains { $0.fields[0] == "hablar" })
    }

    func testANameWithTheNestingSeparatorIsCleaned() throws {
        let odd = Deck(name: "A::B", cards: [Card(front: "x", back: "y")])
        let (_, package) = try export(.deck(odd.id), decks: [odd])
        XCTAssertTrue(package.decks.values.contains("A - B"))
        XCTAssertEqual(AnkiExport.cleanDeckName("   "), "Untitled")
    }

    // MARK: Notes

    func testEveryCardIsABasicNoteWithEscapedHTML() throws {
        let (_, package) = try export(.deck(regular.id))
        XCTAssertEqual(package.notes.map(\.fields), [
            ["hablar", "to speak"],
            ["line one<br>line two", "a &lt; b &amp; c &gt; d"],
        ])
        let model = try XCTUnwrap(package.models[AnkiExport.modelID])
        XCTAssertEqual(model.name, "Basic")
        XCTAssertEqual(model.fieldNames, ["Front", "Back"])
        XCTAssertFalse(model.isCloze)
        XCTAssertTrue(package.notes.allSatisfy { $0.modelID == AnkiExport.modelID })
    }

    func testEscaping() {
        XCTAssertEqual(AnkiExport.escape("a & b < c > d"), "a &amp; b &lt; c &gt; d")
        XCTAssertEqual(AnkiExport.escape("one\r\ntwo\rthree\nfour"), "one<br>two<br>three<br>four")
        XCTAssertEqual(AnkiExport.escapeAttribute("say \"hi\" & <go>"), "say &quot;hi&quot; &amp; &lt;go&gt;")
        XCTAssertEqual(AnkiText.plain(AnkiExport.escape("a < b & c\nd")), "a < b & c\nd", "escaping and reading are inverses")
    }

    /// The GUID column of every note in a package, in note order.
    private func guids(_ data: Data) throws -> [String] {
        let zip = try ZipArchive(data: data)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("guid-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        try XCTUnwrap(try zip.contents(named: "collection.anki2")).write(to: url)
        let db = try SQLiteFile(url: url, readOnly: true)
        defer { db.close() }
        return try db.query("SELECT guid FROM notes ORDER BY id").compactMap { $0[0].text }
    }

    func testGUIDsAndDeckIdsAreStablePerCardAndNotesKeepTheirOrder() throws {
        var draft = ExportDraft(target: .library)
        draft.format = .anki
        let early = try AnkiExport.package(for: draft, subjects: subjects, decks: decks, loadPicture: { _ in nil }, now: Date(timeIntervalSince1970: 1_800_000_000))
        let late = try AnkiExport.package(for: draft, subjects: subjects, decks: decks, loadPicture: { _ in nil }, now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(try guids(early.data), try guids(late.data), "the same cards match on re-import, whenever exported")
        XCTAssertEqual(
            try guids(early.data),
            [regular, phrases, loose].flatMap(\.cards).map { AnkiExport.guid(from: $0.id) }
        )
        let one = try AnkiPackage(data: early.data), two = try AnkiPackage(data: late.data)
        XCTAssertEqual(Set(one.decks.keys), Set(two.decks.keys))
        XCTAssertEqual(one.notes.map(\.fields), two.notes.map(\.fields))
        XCTAssertEqual(Set(one.notes.map(\.id)).count, one.notes.count, "ids are unique")

        let id = regular.cards[0].id
        XCTAssertNotEqual(AnkiExport.guid(from: id), AnkiExport.guid(from: regular.cards[1].id))
        XCTAssertFalse(AnkiExport.guid(from: id).isEmpty)
        XCTAssertGreaterThan(AnkiExport.stableID(from: id), 1_000_000_000_000)
    }

    func testTheChecksumIsAnkisFieldChecksum() {
        XCTAssertEqual(AnkiExport.checksum("hola"), 2_575_305_605)
        XCTAssertEqual(AnkiExport.checksum("café"), 4_096_017_706)
    }

    // MARK: The database

    func testTheCollectionIsAWellFormedLegacyDatabase() throws {
        let (result, _) = try export(.library)
        let zip = try ZipArchive(data: result.data)
        XCTAssertEqual(zip.entries.map(\.name).prefix(2), ["collection.anki2", "media"])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("check-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        try XCTUnwrap(try zip.contents(named: "collection.anki2")).write(to: url)
        let db = try SQLiteFile(url: url, readOnly: true)
        defer { db.close() }

        XCTAssertEqual(try db.query("PRAGMA integrity_check").first?.first?.text, "ok")
        XCTAssertEqual(try db.query("SELECT ver FROM col").first?.first?.int, 11)
        XCTAssertEqual(try db.query("SELECT count(*) FROM notes").first?.first?.int, 4)
        XCTAssertEqual(try db.query("SELECT count(*) FROM cards").first?.first?.int, 4)
        XCTAssertEqual(try db.query("SELECT count(*) FROM cards WHERE type = 0 AND queue = 0 AND reps = 0 AND factor = 0").first?.first?.int, 4, "every card is new")
        XCTAssertEqual(try db.query("SELECT count(*) FROM revlog").first?.first?.int, 0, "no history")
        let csum = try db.query("SELECT csum FROM notes WHERE sfld = 'hola'").first?.first?.int
        XCTAssertEqual(csum, 2_575_305_605)
    }

    // MARK: Pictures

    func testPicturesAreWrittenOnceWithTheirDescriptionAndReferencedInTheField() throws {
        let image = CardImage(fileName: "AAAA.png", altText: "A \"blue\" square")
        let shared = Deck(name: "Pics", cards: [
            Card(front: "one", back: "x", frontImage: image),
            Card(front: "two", back: "y", frontImage: image, backImage: CardImage(fileName: "BBBB.png", altText: nil)),
            Card(front: "gone", back: "z", frontImage: CardImage(fileName: "missing.png", altText: nil)),
        ])
        let (result, package) = try export(.deck(shared.id), decks: [shared]) { [picture] in
            $0.fileName == "missing.png" ? nil : picture
        }
        XCTAssertEqual(result.pictureCount, 2, "AAAA once, BBBB once")
        XCTAssertEqual(result.missingPictures, 1)
        XCTAssertEqual(package.mediaCount, 2)
        XCTAssertEqual(package.mediaData(named: "AAAA.png"), picture)
        XCTAssertEqual(package.notes[0].fields[0], "<img src=\"AAAA.png\" alt=\"A &quot;blue&quot; square\"><br>one")
        XCTAssertEqual(package.notes[1].fields[1], "<img src=\"BBBB.png\"><br>y")
        XCTAssertEqual(package.notes[2].fields[0], "gone", "a card whose picture can't be read goes without it")
    }

    func testACardWithOnlyAPictureHasNoStrayBreak() throws {
        let deck = Deck(name: "P", cards: [Card(front: "", back: "x", frontImage: CardImage(fileName: "a.png", altText: nil))])
        let (_, package) = try export(.deck(deck.id), decks: [deck]) { [picture] _ in picture }
        XCTAssertEqual(package.notes[0].fields[0], "<img src=\"a.png\">")
    }

    func testTheSizeEstimateGrowsWithPictures() {
        var draft = ExportDraft(target: .deck(regular.id))
        draft.format = .anki
        let plain = AnkiExport.estimatedBytes(for: draft, subjects: subjects, decks: decks) { _ in 0 }
        let withPic = Deck(id: regular.id, name: "Regular", cards: [Card(front: "a", back: "b", frontImage: CardImage(fileName: "x.png", altText: nil))])
        let big = AnkiExport.estimatedBytes(for: draft, subjects: subjects, decks: [withPic]) { _ in 500_000 }
        XCTAssertGreaterThan(plain, 20_000)
        XCTAssertGreaterThan(big, 500_000)
    }

    // MARK: Round trip

    func testAnExportedSubjectImportsBackWithTheSameStructureTextAndPictures() throws {
        let image = CardImage(fileName: "AAAA.png", altText: nil)
        let withPicture = Deck(
            name: "Regular", cards: [Card(front: "hablar", back: "to speak", frontImage: image), Card(front: "multi\nline", back: "a & b")],
            subjectID: verbs.id
        )
        let (result, _) = try export(.subject(spanish.id), decks: [withPicture, phrases]) { [picture] _ in picture }

        let package = try AnkiPackage(data: result.data)
        var imported = AnkiImport.plan(
            package: package, selectedDeckIDs: Set(package.notes.map(\.deckID)), library: Library()
        )
        XCTAssertEqual(imported.plan.newSubjects.map(\.name), ["Spanish", "Grammar", "Verbs"])
        XCTAssertEqual(Set(imported.plan.newDecks.map(\.name)), ["Regular", "Phrases"])
        let regularBack = try XCTUnwrap(imported.plan.newDecks.first { $0.name == "Regular" })
        XCTAssertEqual(regularBack.cards.map(\.front), ["hablar", "multi\nline"])
        XCTAssertEqual(regularBack.cards.map(\.back), ["to speak", "a & b"])
        XCTAssertEqual(regularBack.subjectID, imported.plan.newSubjects[2].id)
        XCTAssertEqual(imported.pictures.count, 1)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imgs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CardImageStore(directory: directory)
        AnkiImport.attach(imported.pictures, to: &imported.plan, package: package, store: store)
        let back = try XCTUnwrap(imported.plan.newDecks.first { $0.name == "Regular" }?.cards.first)
        let stored = try XCTUnwrap(back.frontImage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: stored).path))
    }

    func testFiveThousandCardsExportQuickly() throws {
        let cards = (0..<5_000).map { Card(front: "front \($0) <b>", back: "back \($0)\nsecond") }
        let big = Deck(name: "Big", cards: cards)
        let started = Date()
        let (result, package) = try export(.deck(big.id), decks: [big])
        XCTAssertEqual(result.cardCount, 5_000)
        XCTAssertEqual(package.notes.count, 5_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0)
    }

    func testNothingIncludedWritesAnEmptyButValidPackage() throws {
        var draft = ExportDraft(target: .deck(empty.id))
        draft.format = .anki
        let result = try AnkiExport.package(for: draft, subjects: subjects, decks: decks, loadPicture: { _ in nil })
        XCTAssertEqual(result.cardCount, 0)
        XCTAssertEqual(try AnkiPackage(data: result.data).notes.count, 0)
    }
}

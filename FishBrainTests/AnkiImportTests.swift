import AppKit
import XCTest

/// Builds small Anki packages for tests: a zip with a legacy collection database, the media map and files.
enum AnkiFixture {
    struct Model {
        var id: Int64
        var name: String
        var isCloze = false
        var fields: [String] = ["Front", "Back"]
        var templates = 1
    }

    struct Note {
        var id: Int64
        var model: Int64
        var deck: Int64
        var fields: [String]
    }

    static let basic = Model(id: 1, name: "Basic")
    static let reversed = Model(id: 2, name: "Basic (and reversed card)", templates: 2)
    static let cloze = Model(id: 3, name: "Cloze", isCloze: true, fields: ["Text", "Back Extra"])
    static let occlusion = Model(id: 4, name: "Image Occlusion", isCloze: true, fields: ["Occlusion", "Image"])

    /// A package. `collectionName` is the entry the database goes in.
    static func package(
        decks: [Int64: String],
        models: [Model] = [basic, reversed, cloze, occlusion],
        notes: [Note],
        media: [String: Data] = [:],
        collectionName: String = "collection.anki2",
        extraEntries: [(name: String, data: Data)] = []
    ) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteFile(url: url, readOnly: false)
        try db.exec("""
        CREATE TABLE col (id integer primary key, crt integer, mod integer, scm integer, ver integer, dty integer, usn integer,
                          ls integer, conf text, models text, decks text, dconf text, tags text);
        CREATE TABLE notes (id integer primary key, guid text, mid integer, mod integer, usn integer, tags text, flds text,
                            sfld text, csum integer, flags integer, data text);
        CREATE TABLE cards (id integer primary key, nid integer, did integer, ord integer, mod integer, usn integer,
                            type integer, queue integer, due integer, ivl integer, factor integer, reps integer,
                            lapses integer, left integer, odue integer, odid integer, flags integer, data text);
        """)

        func json(_ object: Any) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
        }
        var modelObject: [String: Any] = [:]
        for model in models {
            modelObject[String(model.id)] = [
                "name": model.name, "type": model.isCloze ? 1 : 0,
                "flds": model.fields.map { ["name": $0] },
                "tmpls": (0..<model.templates).map { ["name": "Card \($0 + 1)"] },
            ] as [String: Any]
        }
        var deckObject: [String: Any] = [:]
        for (id, name) in decks { deckObject[String(id)] = ["name": name] }
        try db.query(
            "INSERT INTO col VALUES (1, 0, 0, 0, 11, 0, 0, 0, '{}', ?, ?, '{}', '{}')",
            [.text(json(modelObject)), .text(json(deckObject))]
        )

        var cardID: Int64 = 1000
        for note in notes {
            let flds = note.fields.joined(separator: "\u{1F}")
            try db.query(
                "INSERT INTO notes VALUES (?, ?, ?, 0, 0, '', ?, ?, 0, 0, '')",
                [.int(note.id), .text("guid\(note.id)"), .int(note.model), .text(flds), .text(note.fields.first ?? "")]
            )
            let templates = models.first { $0.id == note.model }?.templates ?? 1
            for ord in 0..<max(1, templates) {
                cardID += 1
                try db.query(
                    "INSERT INTO cards VALUES (?, ?, ?, ?, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, '')",
                    [.int(cardID), .int(note.id), .int(note.deck), .int(Int64(ord))]
                )
            }
        }
        db.close()

        var files: [(name: String, data: Data)] = [(collectionName, try Data(contentsOf: url))]
        var mediaMap: [String: String] = [:]
        for (index, entry) in media.sorted(by: { $0.key < $1.key }).enumerated() {
            mediaMap[String(index)] = entry.key
            files.append((String(index), entry.value))
        }
        files.append(("media", Data(json(mediaMap).utf8)))
        files += extraEntries
        return ZipArchive.write(files)
    }

    /// A tiny valid PNG.
    static func png(side: Int = 8) -> Data {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.systemIndigo.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try! CardImageStore.encode(context.makeImage()!, png: true)
    }
}

final class ZipArchiveTests: XCTestCase {
    private let big = Data(String(repeating: "FishBrain ", count: 400).utf8)

    func testRoundTripsStoredAndDeflatedEntries() throws {
        let small = Data("hi".utf8)
        let zip = try ZipArchive(data: ZipArchive.write([("small.txt", small), ("big.txt", big), ("empty", Data())]))
        XCTAssertEqual(zip.entries.map(\.name), ["small.txt", "big.txt", "empty"])
        XCTAssertEqual(zip.entry(named: "small.txt")?.method, 0, "short files are stored")
        XCTAssertEqual(zip.entry(named: "big.txt")?.method, 8, "repetitive ones are deflated")
        XCTAssertLessThan(zip.entry(named: "big.txt")!.compressedSize, big.count)
        XCTAssertEqual(try zip.contents(named: "small.txt"), small)
        XCTAssertEqual(try zip.contents(named: "big.txt"), big)
        XCTAssertEqual(try zip.contents(named: "empty"), Data())
        XCTAssertNil(try zip.contents(named: "missing"))
    }

    func testACorruptedEntryFailsItsChecksum() throws {
        var bytes = ZipArchive.write([("a.txt", Data("hello world".utf8))])
        // The stored payload follows the 30-byte header and the 5-byte name.
        bytes[35] ^= 0xFF
        let zip = try ZipArchive(data: bytes)
        XCTAssertThrowsError(try zip.contents(named: "a.txt")) {
            XCTAssertEqual($0 as? ZipArchive.ZipError, .corrupt("checksum"))
        }
    }

    func testNamesThatClimbOutAreRefused() {
        for name in ["../evil", "a/../../evil", "/etc/passwd", "C:/x", "a\\b"] {
            let zip = ZipArchive.write([(name, Data("x".utf8))])
            XCTAssertThrowsError(try ZipArchive(data: zip), name) {
                guard case ZipArchive.ZipError.unsafePath = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertNoThrow(try ZipArchive(data: ZipArchive.write([("media/1.jpg", Data("x".utf8))])))
    }

    func testWhatAZipClaimsToHoldIsCapped() {
        let zip = ZipArchive.write([("big.txt", big)])
        XCTAssertThrowsError(try ZipArchive(data: zip, maxUncompressedBytes: 100)) {
            XCTAssertEqual($0 as? ZipArchive.ZipError, .tooLarge(bytes: big.count, limit: 100))
        }
    }

    func testNotAZip() {
        XCTAssertThrowsError(try ZipArchive(data: Data())) { XCTAssertEqual($0 as? ZipArchive.ZipError, .notAZip) }
        XCTAssertThrowsError(try ZipArchive(data: Data(repeating: 7, count: 500))) {
            XCTAssertEqual($0 as? ZipArchive.ZipError, .notAZip)
        }
    }

    func testCRC32MatchesTheKnownValue() {
        XCTAssertEqual(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }
}

final class AnkiTextTests: XCTestCase {
    func testPlainText() {
        XCTAssertEqual(AnkiText.plain("<b>hola</b> amigo"), "hola amigo")
        XCTAssertEqual(AnkiText.plain("line one<br>line two<br/>three<BR />four"), "line one\nline two\nthree\nfour")
        XCTAssertEqual(AnkiText.plain("<div>first</div><div>second</div>"), "first\nsecond")
        XCTAssertEqual(AnkiText.plain("a&nbsp;b &amp; c &lt;d&gt; &quot;e&quot; &#39;f&#39; &#x41;"), "a b & c <d> \"e\" 'f' A")
        XCTAssertEqual(AnkiText.plain("hola [sound:hola.mp3]"), "hola")
        XCTAssertEqual(AnkiText.plain("<img src=\"a.jpg\">"), "")
        XCTAssertEqual(AnkiText.plain("a<br><br><br><br>b"), "a\n\nb")
        XCTAssertEqual(AnkiText.plain("  fish & chips &unknown; "), "fish & chips &unknown;")
    }

    func testPictureNames() {
        XCTAssertEqual(AnkiText.pictureNames(in: "<img src=\"a.jpg\">text<img alt=x src='b b.png'>"), ["a.jpg", "b b.png"])
        XCTAssertEqual(AnkiText.pictureNames(in: "<IMG SRC=c.gif>"), ["c.gif"])
        XCTAssertEqual(AnkiText.pictureNames(in: "<img src=\"caf%C3%A9.jpg\">"), ["café.jpg"])
        XCTAssertEqual(AnkiText.pictureNames(in: "no pictures <b>here</b>"), [])
    }

    func testSoundCount() {
        XCTAssertEqual(AnkiText.soundCount(in: "a [sound:x.mp3] b [sound:y.mp3]"), 2)
        XCTAssertEqual(AnkiText.soundCount(in: "none"), 0)
    }

    func testCloze() {
        let text = "The {{c1::heart}} pumps {{c2::blood::fluid}} and {{c1::oxygen}}."
        XCTAssertEqual(AnkiText.clozeNumbers(in: text), [1, 2])
        XCTAssertEqual(AnkiText.cloze(text, hiding: 1), "The […] pumps blood and […].")
        XCTAssertEqual(AnkiText.cloze(text, hiding: 2), "The heart pumps […] and oxygen.")
        XCTAssertEqual(AnkiText.cloze(text, hiding: nil), "The heart pumps blood and oxygen.")
        XCTAssertEqual(AnkiText.clozeNumbers(in: "no blanks"), [])
    }
}

final class AnkiPackageTests: XCTestCase {
    private let spanish: [Int64: String] = [10: "Spanish A1", 11: "Spanish A1::Verbs", 12: "Spanish A1::Vocabulary"]

    private func basicNotes() -> [AnkiFixture.Note] {
        [
            .init(id: 1, model: 1, deck: 11, fields: ["hablar", "to speak"]),
            .init(id: 2, model: 1, deck: 12, fields: ["la mesa", "the table"]),
        ]
    }

    func testReadsDecksModelsNotesAndTheNotesDeck() throws {
        let data = try AnkiFixture.package(decks: spanish, notes: basicNotes())
        let package = try AnkiPackage(data: data)
        XCTAssertEqual(package.decks[11], "Spanish A1::Verbs")
        XCTAssertEqual(package.models[2]?.templateCount, 2)
        XCTAssertEqual(package.models[3]?.isCloze, true)
        XCTAssertEqual(package.notes.map(\.fields), [["hablar", "to speak"], ["la mesa", "the table"]])
        XCTAssertEqual(package.notes.map(\.deckID), [11, 12])
        XCTAssertEqual(package.byteCount, data.count)
    }

    func testMediaIsFoundByItsOriginalName() throws {
        let picture = AnkiFixture.png()
        let data = try AnkiFixture.package(decks: spanish, notes: basicNotes(), media: ["mesa.png": picture, "b.mp3": Data("x".utf8)])
        let package = try AnkiPackage(data: data)
        XCTAssertEqual(package.mediaCount, 2)
        XCTAssertEqual(package.mediaData(named: "mesa.png"), picture)
        XCTAssertTrue(package.hasMedia(named: "b.mp3"))
        XCTAssertNil(package.mediaData(named: "missing.png"))
    }

    func testPrefersTheLegacyCollectionOverThePlaceholder() throws {
        // Newer Anki's compatibility export: the real database in `.anki21`, a placeholder in `.anki2`.
        let placeholder = try AnkiFixture.package(decks: [1: "Default"], notes: [.init(id: 9, model: 1, deck: 1, fields: ["Please update", "x"])])
        let placeholderDB = try XCTUnwrap(try ZipArchive(data: placeholder).contents(named: "collection.anki2"))
        let real = try AnkiFixture.package(
            decks: spanish, notes: basicNotes(), collectionName: "collection.anki21",
            extraEntries: [("collection.anki2", placeholderDB)]
        )
        let package = try AnkiPackage(data: real)
        XCTAssertEqual(package.notes.count, 2)
    }

    func testTheCompressedFormatIsRecognisedAndRefused() throws {
        let data = try AnkiFixture.package(
            decks: spanish, notes: basicNotes(),
            extraEntries: [("collection.anki21b", Data([0x28, 0xB5, 0x2F, 0xFD, 1, 2, 3]))]
        )
        XCTAssertThrowsError(try AnkiPackage(data: data)) { XCTAssertEqual($0 as? AnkiPackageError, .newerFormat) }
        XCTAssertTrue(AnkiImport.failureMessage(.newerFormat).contains("Support older Anki versions"))
    }

    func testAZipWithoutACollectionIsNotAPackage() {
        let zip = ZipArchive.write([("notes.txt", Data("hi".utf8))])
        XCTAssertThrowsError(try AnkiPackage(data: zip)) { XCTAssertEqual($0 as? AnkiPackageError, .notAPackage) }
        XCTAssertThrowsError(try AnkiPackage(data: Data("just text".utf8))) { XCTAssertEqual($0 as? AnkiPackageError, .notAPackage) }
    }

    func testAnUnknownDatabaseLayoutIsCalledNewer() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteFile(url: url, readOnly: false)
        try db.exec("CREATE TABLE col (id integer primary key, ver integer); INSERT INTO col VALUES (1, 18);")
        db.close()
        let zip = ZipArchive.write([("collection.anki2", try Data(contentsOf: url))])
        XCTAssertThrowsError(try AnkiPackage(data: zip)) { XCTAssertEqual($0 as? AnkiPackageError, .newerFormat) }
    }

    func testUnsafeNamesAndOversizeAreRefused() {
        let unsafe = ZipArchive.write([("../collection.anki2", Data("x".utf8))])
        XCTAssertThrowsError(try AnkiPackage(data: unsafe)) { XCTAssertEqual($0 as? AnkiPackageError, .unsafe) }
        XCTAssertTrue(AnkiImport.failureMessage(.tooLarge(bytes: 612_000_000, limit: 250_000_000)).contains("smaller parts"))
    }
}

final class AnkiImportPlanTests: XCTestCase {
    private let decks: [Int64: String] = [
        10: "Spanish A1", 11: "Spanish A1::Verbs", 12: "Spanish A1::Vocabulary", 20: "Biology", 1: "Default",
    ]

    private func plan(
        _ notes: [AnkiFixture.Note], decks custom: [Int64: String]? = nil, media: [String: Data] = [:],
        selected: Set<Int64>? = nil, library: Library = Library(), context: Subject.ID? = nil,
        models: [AnkiFixture.Model] = [AnkiFixture.basic, AnkiFixture.reversed, AnkiFixture.cloze, AnkiFixture.occlusion]
    ) throws -> (AnkiImport.Result, AnkiPackage) {
        let data = try AnkiFixture.package(decks: custom ?? decks, models: models, notes: notes, media: media)
        let package = try AnkiPackage(data: data)
        let ids = selected ?? Set(package.notes.map(\.deckID))
        return (AnkiImport.plan(package: package, selectedDeckIDs: ids, library: library, contextSubjectID: context), package)
    }

    func testTreatments() {
        XCTAssertEqual(AnkiImport.treatment(for: AnkiPackage.Model(id: 1, name: "Basic", isCloze: false, fieldNames: ["F", "B"], templateCount: 1)), .asIs)
        XCTAssertEqual(AnkiImport.treatment(for: AnkiPackage.Model(id: 1, name: "Basic (and reversed card)", isCloze: false, fieldNames: ["F", "B"], templateCount: 2)), .oneCardOfTwo)
        XCTAssertEqual(AnkiImport.treatment(for: AnkiPackage.Model(id: 1, name: "Cloze", isCloze: true, fieldNames: ["Text"], templateCount: 1)), .clozeBlanks)
        XCTAssertEqual(AnkiImport.treatment(for: AnkiPackage.Model(id: 1, name: "Image Occlusion", isCloze: true, fieldNames: ["O"], templateCount: 1)), .unsupported)
        XCTAssertEqual(AnkiImport.treatment(for: AnkiPackage.Model(id: 1, name: "One field", isCloze: false, fieldNames: ["F"], templateCount: 1)), .unsupported)
        XCTAssertEqual(AnkiImport.treatment(for: nil), .unsupported)
    }

    func testOverviewCountsDecksTypesPicturesAndSounds() throws {
        let png = AnkiFixture.png()
        let data = try AnkiFixture.package(decks: decks, notes: [
            .init(id: 1, model: 1, deck: 11, fields: ["<img src=\"a.png\">hablar", "to speak [sound:s.mp3]"]),
            .init(id: 2, model: 1, deck: 11, fields: ["comer", "to eat"]),
            .init(id: 3, model: 2, deck: 12, fields: ["la mesa", "the table"]),
            .init(id: 4, model: 4, deck: 20, fields: ["occ", "img"]),
        ], media: ["a.png": png])
        let overview = AnkiImport.overview(of: try AnkiPackage(data: data))
        XCTAssertEqual(overview.noteCount, 4)
        XCTAssertEqual(overview.decks.map(\.fullName), ["Biology", "Spanish A1::Verbs", "Spanish A1::Vocabulary"])
        XCTAssertEqual(overview.decks.map(\.noteCount), [1, 2, 1])
        XCTAssertEqual(overview.types.first?.name, "Basic")
        XCTAssertEqual(overview.types.first?.noteCount, 2)
        XCTAssertEqual(overview.types.first { $0.name == "Image Occlusion" }?.treatment, .unsupported)
        XCTAssertEqual(overview.pictureCount, 1)
        XCTAssertEqual(overview.soundCount, 1)
        XCTAssertEqual(overview.decks[1].depth, 1)
        XCTAssertEqual(overview.decks[1].name, "Verbs")
    }

    func testNestedDecksBecomeSubjectsAndDecks() throws {
        let (result, _) = try plan([
            .init(id: 1, model: 1, deck: 11, fields: ["hablar", "to speak"]),
            .init(id: 2, model: 1, deck: 12, fields: ["la mesa", "the table"]),
            .init(id: 3, model: 1, deck: 20, fields: ["cell", "unit of life"]),
        ])
        let p = result.plan
        XCTAssertEqual(p.newSubjects.map(\.name), ["Spanish A1"])
        XCTAssertEqual(p.newDecks.map(\.name), ["Verbs", "Vocabulary", "Biology"])
        XCTAssertEqual(p.newDecks[0].subjectID, p.newSubjects[0].id)
        XCTAssertNil(p.newDecks[2].subjectID, "a deck with nothing above it is loose")
        XCTAssertEqual(p.cardCount, 3)
        XCTAssertEqual(p.openTarget, .subject(p.newSubjects[0].id))
    }

    func testAParentDeckWithItsOwnNotesGetsADeckInsideItsSubject() throws {
        let (result, _) = try plan([
            .init(id: 1, model: 1, deck: 10, fields: ["parent card", "x"]),
            .init(id: 2, model: 1, deck: 11, fields: ["hablar", "to speak"]),
        ])
        XCTAssertEqual(result.plan.newSubjects.map(\.name), ["Spanish A1"])
        XCTAssertEqual(Set(result.plan.newDecks.map(\.name)), ["Spanish A1", "Verbs"])
        XCTAssertTrue(result.plan.newDecks.allSatisfy { $0.subjectID == result.plan.newSubjects[0].id })
    }

    func testOnlyTickedDecksAreImported() throws {
        let (result, _) = try plan([
            .init(id: 1, model: 1, deck: 11, fields: ["a", "b"]),
            .init(id: 2, model: 1, deck: 12, fields: ["c", "d"]),
        ], selected: [12])
        XCTAssertEqual(result.plan.newDecks.map(\.name), ["Vocabulary"])
        XCTAssertEqual(result.plan.cardCount, 1)
    }

    func testReversedNotesBecomeOneCardAndClozeOneCardPerBlankNumber() throws {
        let (result, _) = try plan([
            .init(id: 1, model: 2, deck: 20, fields: ["front", "back"]),
            .init(id: 2, model: 3, deck: 20, fields: ["The {{c1::heart}} pumps {{c2::blood}}.", "Extra note"]),
        ])
        let cards = result.plan.newDecks[0].cards
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[0].front, "front")
        XCTAssertEqual(cards[1].front, "The […] pumps blood.")
        XCTAssertEqual(cards[2].front, "The heart pumps […].")
        XCTAssertEqual(cards[1].back, "The heart pumps blood.\n\nExtra note")
    }

    func testUnsupportedAndEmptyNotesAreSkippedWithWords() throws {
        let (result, _) = try plan([
            .init(id: 1, model: 4, deck: 20, fields: ["Map of Spain", "x"]),
            .init(id: 2, model: 1, deck: 20, fields: ["", "no front"]),
            .init(id: 3, model: 1, deck: 20, fields: ["no back", "<br>"]),
            .init(id: 4, model: 3, deck: 20, fields: ["a sentence without blanks", ""]),
            .init(id: 5, model: 1, deck: 20, fields: ["fine", "ok"]),
            .init(id: 6, model: 99, deck: 20, fields: ["lost", "type"]),
        ])
        XCTAssertEqual(result.plan.cardCount, 1)
        XCTAssertEqual(result.plan.skipped.map(\.text), [
            "Image Occlusion note · “Map of Spain” · type not supported",
            "“(no text)” · empty front",
            "“no back” · empty back",
            "“a sentence without blanks” · cloze note without blanks",
            "Unknown type note · “lost” · type not supported",
        ])
    }

    func testPicturesKeepTheFirstPerSideAndNoteTheRest() throws {
        let png = AnkiFixture.png()
        let (result, package) = try plan([
            .init(id: 1, model: 1, deck: 20, fields: ["<img src=\"a.png\"><img src=\"b.png\">cell", "<img src=\"gone.png\">unit"]),
            .init(id: 2, model: 1, deck: 20, fields: ["<img src=\"a.png\">", "answer"]),
        ], media: ["a.png": png, "b.png": png])
        XCTAssertEqual(result.pictures.count, 2)
        XCTAssertEqual(result.pictures[0].side, .front)
        XCTAssertEqual(result.pictures[0].mediaName, "a.png")
        XCTAssertEqual(result.plan.cardCount, 2, "a card with only a picture on its front is kept")
        XCTAssertEqual(result.plan.newDecks[0].cards[1].front, "")
        XCTAssertEqual(result.plan.notices, [
            "“cell” · 1 extra picture on the front not kept",
            "“cell” · picture “gone.png” is not in the package",
        ])
        XCTAssertTrue(package.hasMedia(named: "b.png"))
    }

    func testSoundsAreCountedNotImported() throws {
        let (result, _) = try plan([
            .init(id: 1, model: 1, deck: 20, fields: ["hola [sound:a.mp3]", "hello [sound:b.mp3]"]),
        ])
        XCTAssertEqual(result.soundCount, 2)
        XCTAssertEqual(result.plan.newDecks[0].cards[0].front, "hola")
    }

    func testDeepDecksJoinTheDeckNameAndContextNests() throws {
        let deep: [Int64: String] = [30: "A::B::C::D::Verbs"]
        let (result, _) = try plan([.init(id: 1, model: 1, deck: 30, fields: ["a", "b"])], decks: deep)
        XCTAssertEqual(result.plan.newSubjects.map(\.name), ["A", "B", "C", "D"].prefix(3).map { $0 })
        XCTAssertEqual(result.plan.newDecks.map(\.name), ["D - Verbs"])

        let top = Subject(name: "Languages")
        let (inside, _) = try plan(
            [.init(id: 1, model: 1, deck: 11, fields: ["a", "b"])], library: Library(subjects: [top]), context: top.id
        )
        XCTAssertEqual(inside.plan.newSubjects.map(\.name), ["Spanish A1"])
        XCTAssertEqual(inside.plan.newSubjects[0].parentID, top.id)
    }

    func testHTMLIsFlattenedInCardText() throws {
        let (result, _) = try plan([
            .init(id: 1, model: 1, deck: 20, fields: ["<b>mitosis</b><br>(cell division)", "<div>one</div><div>two &amp; three</div>"]),
        ])
        XCTAssertEqual(result.plan.newDecks[0].cards[0].front, "mitosis\n(cell division)")
        XCTAssertEqual(result.plan.newDecks[0].cards[0].back, "one\ntwo & three")
    }

    func testAttachStoresPicturesOnceAndNotesUnreadableOnes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imgs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CardImageStore(directory: directory)
        var (result, package) = try plan([
            .init(id: 1, model: 1, deck: 20, fields: ["<img src=\"a.png\">one", "x"]),
            .init(id: 2, model: 1, deck: 20, fields: ["<img src=\"a.png\">two", "y"]),
            .init(id: 3, model: 1, deck: 20, fields: ["<img src=\"bad.png\">three", "z"]),
        ], media: ["a.png": AnkiFixture.png(), "bad.png": Data("not an image".utf8)])

        AnkiImport.attach(result.pictures, to: &result.plan, package: package, store: store)
        let cards = result.plan.newDecks[0].cards
        let first = try XCTUnwrap(cards[0].frontImage)
        XCTAssertEqual(cards[1].frontImage, first, "the same picture is stored once")
        XCTAssertNil(cards[2].frontImage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: first, thumbnail: true).path))
        XCTAssertEqual(result.plan.notices, ["Picture “bad.png” couldn't be read and was left out"])
        _ = package
    }
}

@MainActor
final class AnkiImportStoreTests: XCTestCase {
    private var directory: URL!
    private var undo: UndoManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        undo = UndoManager()
        undo.groupsByEvent = false
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testAnImportWithPicturesUndoesAndRedoesWithTheirFiles() async throws {
        try DeckStorage(directory: directory).save(Library())
        let store = DeckStore(storage: DeckStorage(directory: directory), debounce: .milliseconds(1), onSaved: {})
        store.undoManager = undo

        let data = try AnkiFixture.package(
            decks: [20: "Biology::Cells"],
            notes: [.init(id: 1, model: 1, deck: 20, fields: ["<img src=\"a.png\">cell", "unit"])],
            media: ["a.png": AnkiFixture.png()]
        )
        let package = try AnkiPackage(data: data)
        var result = AnkiImport.plan(package: package, selectedDeckIDs: [20], library: Library())
        AnkiImport.attach(result.pictures, to: &result.plan, package: package, store: store.imageStore)
        let image = try XCTUnwrap(result.plan.newDecks[0].cards[0].frontImage)

        XCTAssertTrue(store.performImport(result.plan))
        XCTAssertEqual(store.subjects.map(\.name), ["Biology"])
        XCTAssertEqual(store.decks.map(\.name), ["Cells"])
        await store.settled()

        // Age the files past the sweep grace, so only the undo retention can keep them.
        let old = Date(timeIntervalSinceNow: -3600)
        for name in image.fileNames {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: store.imageStore.directory.appendingPathComponent(name).path)
        }

        undo.undo()
        XCTAssertTrue(store.decks.isEmpty)
        XCTAssertTrue(store.subjects.isEmpty)
        await store.settled()
        for name in image.fileNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageStore.directory.appendingPathComponent(name).path), "kept for redo")
        }

        undo.redo()
        XCTAssertEqual(store.decks.first?.cards.first?.frontImage, image)
        await store.settled()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageStore.url(for: image).path))
    }
}

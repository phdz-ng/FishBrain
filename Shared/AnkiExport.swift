import CryptoKit
import Foundation

/// Writes decks as an Anki package (`.apkg`): a zip holding a collection in the older schema Anki still
/// imports, a `media` map and the pictures. Every card is a Basic note (Front, Back).
///
/// GUIDs and deck ids are worked out from the cards' and decks' own ids, so exporting the same deck again
/// gives Anki the same ones to match on, instead of a second copy. Study progress and deck colours are
/// not written: they aren't part of what is shared.
enum AnkiExport {
    struct Result: Equatable {
        var data: Data
        var cardCount: Int
        var deckCount: Int
        /// Pictures written into the package.
        var pictureCount: Int
        /// Pictures a card points at whose file couldn't be read, so the card went without.
        var missingPictures: Int
    }

    /// The note type every card uses.
    static let modelID: Int64 = 1_700_000_000_001
    static let modelName = "Basic"

    // MARK: Package

    /// - Parameter loadPicture: the bytes of a card's picture file, or nil when it can't be read.
    static func package(
        for draft: ExportDraft,
        subjects: [Subject],
        decks: [Deck],
        loadPicture: (CardImage) -> Data?,
        now: Date = Date()
    ) throws -> Result {
        let included = draft.includedDecks(subjects: subjects, decks: decks).filter { !$0.cards.isEmpty }
        let root: Subject.ID? = { if case .subject(let id) = draft.target { id } else { nil } }()
        let isSingleDeck: Bool = { if case .deck = draft.target { true } else { false } }()

        // Deck names, and every parent of a nested one, since Anki wants them to exist.
        var names: [(deck: Deck, name: String)] = []
        for deck in included {
            let path = isSingleDeck ? [] : LibraryExport.subjectNames(of: deck, root: root, subjects: subjects)
            let parts = (path + [deck.name]).map(Self.cleanDeckName)
            names.append((deck, parts.joined(separator: "::")))
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fishbrain-export-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let seconds = Int64(now.timeIntervalSince1970)
        let milliseconds = seconds * 1000

        var media: [(name: String, data: Data)] = []
        var mediaNames: [String: String] = [:] // picture file -> name in the package
        var missing = 0

        let db = try SQLiteFile(url: url, readOnly: false)
        defer { db.close() }
        try db.exec(schema)
        try db.exec("BEGIN")

        func html(_ text: String, image: CardImage?) -> String {
            var parts: [String] = []
            if let image {
                if mediaNames[image.fileName] == nil, let data = loadPicture(image) {
                    mediaNames[image.fileName] = image.fileName
                    media.append((image.fileName, data))
                }
                if mediaNames[image.fileName] != nil {
                    let alt = (image.altText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let altAttribute = alt.isEmpty ? "" : " alt=\"\(Self.escapeAttribute(alt))\""
                    parts.append("<img src=\"\(Self.escapeAttribute(image.fileName))\"\(altAttribute)>")
                } else {
                    missing += 1
                }
            }
            if !text.isEmpty { parts.append(escape(text)) }
            return parts.joined(separator: "<br>")
        }

        // Decks.
        var deckIDs: [String: Int64] = [:]
        var deckEntries: [String: Any] = [:]
        func ensureDeck(_ name: String, seed: UUID?) {
            guard deckIDs[name] == nil else { return }
            let id = seed.map { stableID(from: $0) } ?? stableID(from: name)
            deckIDs[name] = id
            deckEntries[String(id)] = deckObject(id: id, name: name, seconds: seconds)
        }
        for (deck, name) in names {
            let parts = name.components(separatedBy: "::")
            for end in 1..<max(1, parts.count) { ensureDeck(parts[..<end].joined(separator: "::"), seed: nil) }
            ensureDeck(name, seed: deck.id)
        }
        deckEntries["1"] = deckObject(id: 1, name: "Default", seconds: seconds)

        // Notes and cards.
        var cardID = milliseconds
        var position = 0
        var cardCount = 0
        for (deck, name) in names {
            guard let deckID = deckIDs[name] else { continue }
            for card in deck.cards {
                // In order of export, so a reader that sorts by id (Anki's browser does) keeps the deck's
                // order. What re-importing matches on is the GUID, which is stable per card.
                position += 1
                let noteID = milliseconds + Int64(position)
                let front = html(card.front, image: card.frontImage)
                let back = html(card.back, image: card.backImage)
                let sortField = AnkiText.plain(front)
                try db.query(
                    "INSERT INTO notes VALUES (?, ?, ?, ?, -1, '', ?, ?, ?, 0, '')",
                    [
                        .int(noteID), .text(guid(from: card.id)), .int(modelID), .int(seconds),
                        .text(front + "\u{1F}" + back), .text(sortField), .int(checksum(sortField)),
                    ]
                )
                cardID += 1
                try db.query(
                    "INSERT INTO cards VALUES (?, ?, ?, 0, ?, -1, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')",
                    [.int(cardID), .int(noteID), .int(deckID), .int(seconds), .int(Int64(position))]
                )
                cardCount += 1
            }
        }

        // The collection row.
        try db.query(
            "INSERT INTO col VALUES (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, '{}')",
            [
                .int(seconds), .int(seconds), .int(milliseconds), .text(json(collectionConfig)),
                .text(json([String(modelID): modelObject(seconds: seconds)])),
                .text(json(deckEntries)), .text(json(["1": deckConfig])),
            ]
        )
        try db.exec("COMMIT")
        db.close()

        var files: [(name: String, data: Data)] = [("collection.anki2", try Data(contentsOf: url))]
        var mediaMap: [String: String] = [:]
        for (index, file) in media.enumerated() {
            mediaMap[String(index)] = file.name
            files.append((String(index), file.data))
        }
        files.insert(("media", Data(json(mediaMap).utf8)), at: 1)

        return Result(
            data: ZipArchive.write(files), cardCount: cardCount, deckCount: names.count,
            pictureCount: media.count, missingPictures: missing
        )
    }

    /// About how big the package will be, for the sheet: the text, the pictures, and a fixed overhead.
    static func estimatedBytes(
        for draft: ExportDraft, subjects: [Subject], decks: [Deck], pictureSize: (CardImage) -> Int
    ) -> Int {
        var bytes = 24_000 // the collection's fixed tables and note type
        var counted = Set<String>()
        for deck in draft.includedDecks(subjects: subjects, decks: decks) {
            for card in deck.cards {
                bytes += 260 + card.front.utf8.count + card.back.utf8.count
                for image in [card.frontImage, card.backImage].compactMap({ $0 }) where counted.insert(image.fileName).inserted {
                    bytes += pictureSize(image)
                }
            }
        }
        return bytes
    }

    // MARK: Text

    /// Plain text as a field: markup characters escaped, line breaks as `<br>`.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    static func escapeAttribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// A name can't contain the `::` that Anki reads as nesting.
    static func cleanDeckName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "::", with: " - ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    // MARK: Ids

    private static let base91 = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&()*+,-./:;<=>?@[]^_`{|}~")

    /// What Anki matches a note by on re-import, from the card's id: the same card is always the same GUID.
    static func guid(from id: UUID) -> String {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        var value: UInt64 = 0
        for index in 0..<8 { value = value << 8 | UInt64(bytes[index] ^ bytes[index + 8]) }
        var result = ""
        repeat {
            result.insert(base91[Int(value % 91)], at: result.startIndex)
            value /= 91
        } while value > 0
        return result
    }

    /// A positive id from a UUID (48 bits, above Anki's own small ids).
    static func stableID(from id: UUID) -> Int64 {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        var value: Int64 = 0
        for index in 0..<6 { value = value << 8 | Int64(bytes[index] ^ bytes[index + 8]) }
        return value + 1_000_000_000_000
    }

    private static func stableID(from name: String) -> Int64 {
        let digest = Insecure.SHA1.hash(data: Data(name.utf8))
        var value: Int64 = 0
        for byte in digest.prefix(6) { value = value << 8 | Int64(byte) }
        return value + 1_000_000_000_000
    }

    /// Anki's field checksum: the first 32 bits of the SHA-1 of the sort field.
    static func checksum(_ field: String) -> Int64 {
        let digest = Insecure.SHA1.hash(data: Data(field.utf8))
        var value: Int64 = 0
        for byte in digest.prefix(4) { value = value << 8 | Int64(byte) }
        return value
    }

    // MARK: Collection

    private static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static let schema = """
    CREATE TABLE col (
        id integer primary key, crt integer not null, mod integer not null, scm integer not null, ver integer not null,
        dty integer not null, usn integer not null, ls integer not null, conf text not null, models text not null,
        decks text not null, dconf text not null, tags text not null
    );
    CREATE TABLE notes (
        id integer primary key, guid text not null, mid integer not null, mod integer not null, usn integer not null,
        tags text not null, flds text not null, sfld integer not null, csum integer not null, flags integer not null,
        data text not null
    );
    CREATE TABLE cards (
        id integer primary key, nid integer not null, did integer not null, ord integer not null, mod integer not null,
        usn integer not null, type integer not null, queue integer not null, due integer not null, ivl integer not null,
        factor integer not null, reps integer not null, lapses integer not null, left integer not null,
        odue integer not null, odid integer not null, flags integer not null, data text not null
    );
    CREATE TABLE revlog (
        id integer primary key, cid integer not null, usn integer not null, ease integer not null, ivl integer not null,
        lastIvl integer not null, factor integer not null, time integer not null, type integer not null
    );
    CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
    CREATE INDEX ix_notes_usn on notes (usn);
    CREATE INDEX ix_cards_usn on cards (usn);
    CREATE INDEX ix_revlog_usn on revlog (usn);
    CREATE INDEX ix_cards_nid on cards (nid);
    CREATE INDEX ix_cards_sched on cards (did, queue, due);
    CREATE INDEX ix_revlog_cid on revlog (cid);
    CREATE INDEX ix_notes_csum on notes (csum);
    """

    private static let collectionConfig: [String: Any] = [
        "activeDecks": [1], "curDeck": 1, "newSpread": 0, "collapseTime": 1200, "timeLim": 0, "estTimes": true,
        "dueCounts": true, "curModel": String(modelID), "nextPos": 1, "sortType": "noteFld",
        "sortBackwards": false, "addToCur": true,
    ]

    private static let deckConfig: [String: Any] = [
        "id": 1, "mod": 0, "name": "Default", "usn": 0, "maxTaken": 60, "autoplay": true, "timer": 0, "replayq": true,
        "new": ["bury": true, "delays": [1, 10], "initialFactor": 2500, "ints": [1, 4, 0], "order": 1, "perDay": 20],
        "rev": ["bury": true, "ease4": 1.3, "ivlFct": 1, "maxIvl": 36500, "perDay": 200, "hardFactor": 1.2],
        "lapse": ["delays": [10], "leechAction": 1, "leechFails": 8, "minInt": 1, "mult": 0],
    ]

    private static func deckObject(id: Int64, name: String, seconds: Int64) -> [String: Any] {
        [
            "id": id, "mod": seconds, "name": name, "usn": -1, "lrnToday": [0, 0], "revToday": [0, 0],
            "newToday": [0, 0], "timeToday": [0, 0], "collapsed": false, "browserCollapsed": false, "desc": "",
            "dyn": 0, "conf": 1, "extendNew": 0, "extendRev": 0,
        ]
    }

    private static func modelObject(seconds: Int64) -> [String: Any] {
        func field(_ name: String, _ ord: Int) -> [String: Any] {
            ["name": name, "ord": ord, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "media": [String]()]
        }
        return [
            "id": modelID, "name": modelName, "type": 0, "mod": seconds, "usn": -1, "sortf": 0, "did": 1,
            "tmpls": [[
                "name": "Card 1", "ord": 0, "qfmt": "{{Front}}",
                "afmt": "{{FrontSide}}\n\n<hr id=answer>\n\n{{Back}}",
                "bqfmt": "", "bafmt": "", "did": NSNull(), "bfont": "", "bsize": 0,
            ] as [String: Any]],
            "flds": [field("Front", 0), field("Back", 1)],
            "css": ".card {\n    font-family: arial;\n    font-size: 20px;\n    text-align: center;\n    color: black;\n    background-color: white;\n}\n",
            "latexPre": "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8]{inputenc}\n\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
            "latexPost": "\\end{document}",
            "latexsvg": false,
            "req": [[0, "any", [0]]],
            "tags": [String](),
            "vers": [Int](),
        ]
    }
}

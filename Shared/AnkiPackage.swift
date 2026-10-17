import Foundation

enum AnkiPackageError: Error, Equatable {
    /// Not a zip, or a zip with no collection in it.
    case notAPackage
    case tooLarge(bytes: Int, limit: Int)
    /// A name inside would unpack outside its folder.
    case unsafe
    /// The newer compressed format (`collection.anki21b`), or a database layout this reader doesn't know.
    case newerFormat
    case unreadable(String)
}

/// What is inside an Anki package (`.apkg`), read and not interpreted: decks, note types, notes, and the
/// media. Reads the older collection layout (the one Anki writes with "Support older Anki versions"); the
/// newer compressed one is recognised and refused.
struct AnkiPackage {
    struct Model: Equatable {
        var id: Int64
        var name: String
        var isCloze: Bool
        var fieldNames: [String]
        var templateCount: Int
    }

    struct Note: Equatable {
        var id: Int64
        var modelID: Int64
        /// The deck of the note's first card.
        var deckID: Int64
        var fields: [String]
    }

    static let maxBytes = ZipArchive.defaultMaxUncompressedBytes

    private(set) var decks: [Int64: String] = [:]
    private(set) var models: [Int64: Model] = [:]
    private(set) var notes: [Note] = []
    /// The size of the file.
    let byteCount: Int
    private let zip: ZipArchive
    /// Original file name -> the entry holding it.
    private var media: [String: String] = [:]

    init(data: Data) throws {
        if data.count > Self.maxBytes { throw AnkiPackageError.tooLarge(bytes: data.count, limit: Self.maxBytes) }
        byteCount = data.count
        do {
            zip = try ZipArchive(data: data, maxUncompressedBytes: Self.maxBytes)
        } catch ZipArchive.ZipError.tooLarge(let bytes, let limit) {
            throw AnkiPackageError.tooLarge(bytes: bytes, limit: limit)
        } catch ZipArchive.ZipError.unsafePath {
            throw AnkiPackageError.unsafe
        } catch ZipArchive.ZipError.notAZip {
            throw AnkiPackageError.notAPackage
        } catch {
            throw AnkiPackageError.unreadable("\(error)")
        }

        // The collection: the legacy one made for older Anki when there is one; the compressed one is
        // only recognised. (Newer Anki also writes a placeholder `collection.anki2` beside it.)
        let name: String
        if zip.entry(named: "collection.anki21") != nil {
            name = "collection.anki21"
        } else if zip.entry(named: "collection.anki21b") != nil {
            throw AnkiPackageError.newerFormat
        } else if zip.entry(named: "collection.anki2") != nil {
            name = "collection.anki2"
        } else {
            throw AnkiPackageError.notAPackage
        }

        let database: Data
        do {
            guard let found = try zip.contents(named: name) else { throw AnkiPackageError.notAPackage }
            database = found
        } catch let error as AnkiPackageError {
            throw error
        } catch ZipArchive.ZipError.tooLarge(let bytes, let limit) {
            throw AnkiPackageError.tooLarge(bytes: bytes, limit: limit)
        } catch {
            throw AnkiPackageError.unreadable("\(error)")
        }

        try readCollection(database)
        readMediaMap()
    }

    var mediaCount: Int { media.count }

    /// The bytes of a media file by the name notes use for it, or nil when the package doesn't hold it.
    func mediaData(named name: String) -> Data? {
        guard let entry = media[name] else { return nil }
        return (try? zip.contents(named: entry)) ?? nil
    }

    func hasMedia(named name: String) -> Bool { media[name] != nil }

    // MARK: Reading

    private mutating func readCollection(_ database: Data) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fishbrain-apkg-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try database.write(to: url)
            let file = try SQLiteFile(url: url, readOnly: true)
            defer { file.close() }

            let collection: [[SQLiteFile.Value]]
            do {
                collection = try file.query("SELECT models, decks FROM col LIMIT 1")
            } catch {
                // The layout that keeps note types in their own tables isn't read.
                throw AnkiPackageError.newerFormat
            }
            guard let row = collection.first, let modelsJSON = row[0].text, let decksJSON = row[1].text else {
                throw AnkiPackageError.notAPackage
            }
            models = Self.parseModels(modelsJSON)
            decks = Self.parseDecks(decksJSON)

            var firstDeck: [Int64: Int64] = [:]
            for card in try file.query("SELECT nid, CASE WHEN odid != 0 THEN odid ELSE did END FROM cards ORDER BY nid, ord") {
                if let note = card[0].int, let deck = card[1].int, firstDeck[note] == nil { firstDeck[note] = deck }
            }
            for note in try file.query("SELECT id, mid, flds FROM notes ORDER BY id") {
                guard let id = note[0].int, let model = note[1].int, let fields = note[2].text else { continue }
                notes.append(Note(
                    id: id, modelID: model, deckID: firstDeck[id] ?? 1,
                    fields: fields.components(separatedBy: "\u{1F}")
                ))
            }
        } catch let error as AnkiPackageError {
            throw error
        } catch {
            throw AnkiPackageError.unreadable("\(error)")
        }
    }

    private mutating func readMediaMap() {
        guard let data = try? zip.contents(named: "media"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        for (entry, name) in object where zip.entry(named: entry) != nil { media[name] = entry }
    }

    static func parseModels(_ json: String) -> [Int64: Model] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [:] }
        var result: [Int64: Model] = [:]
        for (key, value) in object {
            guard let id = Int64(key), let model = value as? [String: Any] else { continue }
            let fields = (model["flds"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let templates = (model["tmpls"] as? [[String: Any]])?.count ?? 1
            result[id] = Model(
                id: id, name: model["name"] as? String ?? "Note type",
                isCloze: (model["type"] as? Int) == 1, fieldNames: fields, templateCount: templates
            )
        }
        return result
    }

    static func parseDecks(_ json: String) -> [Int64: String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [:] }
        var result: [Int64: String] = [:]
        for (key, value) in object {
            if let id = Int64(key), let deck = value as? [String: Any], let name = deck["name"] as? String { result[id] = name }
        }
        return result
    }
}

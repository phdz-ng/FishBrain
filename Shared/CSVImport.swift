import Foundation

/// A CSV file read into rows, before anyone has said which column is what.
struct CSVTable: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        /// Where the record sits in the file, counting from 1 and not counting blank lines: "row 212".
        var number: Int
        var fields: [String]
    }

    var delimiter: CSVDelimiter
    var encoding: TextEncoding
    /// Every record that could be read, the header (if the file has one) first.
    var rows: [Row]
    /// Records whose quoting was broken, by their position.
    var brokenRecords: [Int]

    var columnCount: Int { rows.map(\.fields.count).max() ?? 0 }

    /// A first row naming the columns, as far as can be told: two of the names the column guess knows (Front,
    /// Back, Word, Meaning, Example, Deck…), or one in a file of at most two columns.
    var looksLikeHeader: Bool {
        guard let first = rows.first else { return false }
        let known = CSVColumnMapping.knownNames
        let hits = first.fields.filter { known.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
        return hits.count >= 2 || (first.fields.count <= 2 && !hits.isEmpty)
    }

    /// The names to show over each column: the header's, or "Column 1", "Column 2".
    func columnTitles(hasHeader: Bool) -> [String] {
        let header = hasHeader ? rows.first?.fields ?? [] : []
        return (0..<columnCount).map { index in
            if index < header.count, !header[index].isEmpty { return header[index] }
            return "Column \(index + 1)"
        }
    }

    // MARK: Reading

    static func read(contentsOf url: URL, maxBytes: Int = CardImporter.maxBytes) -> Result<CSVTable, ImportFailure> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
                return .failure(.tooLarge(bytes: size, limit: maxBytes))
            }
            return read(try Data(contentsOf: url), maxBytes: maxBytes)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    static func read(_ data: Data, maxBytes: Int = CardImporter.maxBytes) -> Result<CSVTable, ImportFailure> {
        if data.count > maxBytes { return .failure(.tooLarge(bytes: data.count, limit: maxBytes)) }
        if data.isEmpty { return .failure(.emptyFile) }
        guard let (text, encoding) = CardImporter.decode(data) else { return .failure(.notTextFile) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failure(.emptyFile) }

        let parsed = CSVRecords.parse(text)
        var rows: [Row] = []
        var broken: [Int] = []
        for (index, record) in parsed.records.enumerated() {
            switch record {
            case .fields(let fields): rows.append(Row(number: index + 1, fields: fields))
            case .broken: broken.append(index + 1)
            }
        }
        guard !rows.isEmpty else { return .failure(.noCards(skippedLines: broken.count)) }
        return .success(CSVTable(delimiter: parsed.delimiter, encoding: encoding, rows: rows, brokenRecords: broken))
    }
}

/// Which column of the file is which part of a card. A side can show several columns, one per line, in
/// the order listed.
struct CSVColumnMapping: Equatable, Sendable {
    var front: [Int] = []
    var back: [Int] = []
    var deck: Int?
    var subject: Int?

    /// A card needs at least one column on each side, and no column on both.
    var isUsable: Bool { !front.isEmpty && !back.isEmpty && Set(front).isDisjoint(with: back) }

    /// Every column on the card, front first.
    var cardColumns: [Int] { front + back }

    static let frontNames: Set<String> = ["front", "question", "term", "word", "prompt"]
    static let backNames: Set<String> = ["back", "answer", "definition", "meaning", "translation"]
    /// Columns that add to the back after its main column: an example sentence, a note, how it's said.
    static let extraBackNames: Set<String> = ["example", "examples", "sentence", "note", "notes", "hint", "pronunciation", "ipa"]
    /// Every name the guess knows, for telling a row of column names from a row of cards.
    static let knownNames: Set<String> = frontNames.union(backNames).union(extraBackNames).union(["deck", "subject"])

    /// Matched by the header's names, case-insensitively: one front column, one main back column with any
    /// extra columns (example, note…) after it in file order, the deck and the subject. With no header, or
    /// no match, the first free column is the front and the next one the back.
    static func detect(header: [String]?, columnCount: Int) -> CSVColumnMapping {
        var mapping = CSVColumnMapping()
        var front: Int?
        var back: Int?
        var extras: [Int] = []
        for (index, name) in (header ?? []).enumerated() where index < columnCount {
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            if front == nil, frontNames.contains(key) { front = index }
            else if back == nil, backNames.contains(key) { back = index }
            else if extraBackNames.contains(key) { extras.append(index) }
            else if mapping.deck == nil, key == "deck" { mapping.deck = index }
            else if mapping.subject == nil, key == "subject" { mapping.subject = index }
        }
        let taken = Set([front, back, mapping.deck, mapping.subject].compactMap { $0 } + extras)
        var free = (0..<columnCount).filter { !taken.contains($0) }.makeIterator()
        if front == nil { front = free.next() }
        if back == nil { back = free.next() }
        mapping.front = front.map { [$0] } ?? []
        mapping.back = (back.map { [$0] } ?? []) + extras
        return mapping
    }
}

enum CSVImportDestination: Equatable, Sendable {
    /// Make the decks and subjects the Deck and Subject columns name.
    case fromFile
    /// Put every card in a deck that exists.
    case existingDeck(Deck.ID)
    /// Put every card in a new deck with this name.
    case newDeck(String)
}

struct CSVImportOptions: Equatable, Sendable {
    var hasHeader: Bool
    var mapping: CSVColumnMapping
    var destination: CSVImportDestination
    /// Leave out cards whose front and back are already in the deck they're going to (only for a deck
    /// that exists).
    var skipDuplicates = false
}

/// What an import would do, worked out before anything changes: the new subjects and decks, the cards for
/// decks that exist, the rows left out and why. Pure, so the sheet's preview and the tests use the same rules.
struct CSVImportPlan: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case emptyFront, emptyBack, brokenQuoting
        /// Something that has its own words (an Anki note this reader can't use).
        case custom(String)

        var text: String {
            switch self {
            case .emptyFront: "Empty front"
            case .emptyBack: "Empty back"
            case .brokenQuoting: "Quoting wasn't closed"
            case .custom(let text): text
            }
        }
    }

    struct Skipped: Equatable, Sendable {
        var rowNumber: Int
        var reason: Reason
        var text: String {
            if case .custom(let text) = reason { return text }
            return "Row \(rowNumber): \(reason.text.lowercasedFirst)"
        }
    }

    struct Addition: Equatable, Sendable {
        var deckID: Deck.ID
        var cards: [Card]
    }

    struct PreviewRow: Equatable, Sendable {
        var rowNumber: Int
        /// "Spanish › Grammar › Verbs", the deck's name, or the deck it joins.
        var place: String
        var front: String
        var back: String
        var problem: Reason?
    }

    /// Parents come before the subjects inside them.
    var newSubjects: [Subject] = []
    var newDecks: [Deck] = []
    var additions: [Addition] = []
    var skipped: [Skipped] = []
    /// Things worth saying that left no card out (a picture that wasn't kept).
    var notices: [String] = []
    var duplicateCount = 0
    var preview: [PreviewRow] = []
    /// How many data rows the file has (header excluded).
    var rowCount = 0

    var cardCount: Int {
        newDecks.reduce(0) { $0 + $1.cards.count } + additions.reduce(0) { $0 + $1.cards.count }
    }
    var deckCount: Int { newDecks.count + additions.count }
    var subjectCount: Int { newSubjects.count }
    var isEmpty: Bool { cardCount == 0 }

    /// "412 cards · 8 decks · 3 subjects · 3 rows skipped".
    var summary: String { summary(skipped: "row") }

    /// The same, naming what was left out ("row" for a CSV, "note" for an Anki package).
    func summary(skipped noun: String) -> String {
        var parts = ["\(cardCount) \(cardCount == 1 ? "card" : "cards")"]
        if deckCount != 1 { parts.append("\(deckCount) decks") }
        else if subjectCount > 0 { parts.append("1 deck") }
        if subjectCount > 0 { parts.append("\(subjectCount) \(subjectCount == 1 ? "subject" : "subjects")") }
        if duplicateCount > 0 { parts.append("\(duplicateCount) already there") }
        if !skipped.isEmpty { parts.append("\(skipped.count) \(skipped.count == 1 ? noun : noun + "s") skipped") }
        return parts.joined(separator: " · ")
    }

    /// Where to take the user afterwards: the deck cards went into, else the first subject made, else the
    /// first deck made.
    enum Destination: Equatable, Sendable {
        case deck(Deck.ID)
        case subject(Subject.ID)
    }

    var openTarget: Destination? {
        if let first = additions.first { return .deck(first.deckID) }
        if let top = newSubjects.first(where: { subject in !newSubjects.contains { $0.id == subject.parentID } }) {
            return .subject(top.id)
        }
        return newDecks.first.map { .deck($0.id) }
    }
}

enum CSVImport {
    /// Where the Subject column's path is cut into names.
    static let pathSeparators = ["›", "::", "/"]

    /// "Spanish › Grammar", "Spanish::Grammar" or "Spanish/Grammar" as its names, blanks dropped.
    static func subjectNames(_ text: String) -> [String] {
        var parts = [text]
        for separator in pathSeparators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.compactMap { Subject.cleanName($0) }
    }

    /// Works out what importing `table` does. `contextSubjectID` is the subject the import was started
    /// from: new subjects and loose decks go inside it. `fileName` names the deck for rows that give none.
    static func plan(
        table: CSVTable,
        options: CSVImportOptions,
        library: Library,
        contextSubjectID: Subject.ID? = nil,
        fileName: String
    ) -> CSVImportPlan {
        var plan = CSVImportPlan()
        let mapping = options.mapping
        guard mapping.isUsable else { return plan }

        let tree = SubjectTree(library.subjects)
        let context = contextSubjectID.flatMap { tree.subject($0) }?.id
        let fallbackDeckName = Subject.cleanName(fileName) ?? "Imported cards"

        func cell(_ row: CSVTable.Row, _ column: Int?) -> String {
            guard let column, column < row.fields.count else { return "" }
            return row.fields[column]
        }

        /// A side's cells, one per line in the side's order, empty ones left out.
        func side(_ row: CSVTable.Row, _ columns: [Int]) -> String {
            columns.map { cell(row, $0) }.filter { !$0.isEmpty }.joined(separator: "\n")
        }

        var structure = ImportStructure(library: library, context: context)

        // Cards already in the deck cards are going to, for skipping duplicates.
        var existingKeys: Set<String> = []
        var existingDeck: Deck?
        var newDeckForSingle: Deck?
        switch options.destination {
        case .existingDeck(let id):
            existingDeck = library.decks.first { $0.id == id }
            if options.skipDuplicates, let deck = existingDeck {
                existingKeys = Set(deck.cards.map { key($0.front, $0.back) })
            }
        case .newDeck(let name):
            newDeckForSingle = Deck(name: Subject.cleanName(name) ?? fallbackDeckName, subjectID: context)
        case .fromFile:
            break
        }

        var singleCards: [Card] = []
        let dataRows = options.hasHeader ? Array(table.rows.dropFirst()) : table.rows
        plan.rowCount = dataRows.count + table.brokenRecords.count

        // Rows and broken records in file order, so the report and the preview read like the file.
        enum Item { case row(CSVTable.Row), broken(Int) }
        var items: [Item] = dataRows.map { .row($0) } + table.brokenRecords.map { .broken($0) }
        items.sort { left, right in
            func number(_ item: Item) -> Int {
                switch item { case .row(let row): row.number; case .broken(let number): number }
            }
            return number(left) < number(right)
        }

        for item in items {
            switch item {
            case .broken(let number):
                plan.skipped.append(.init(rowNumber: number, reason: .brokenQuoting))
                if plan.preview.count < 5 {
                    plan.preview.append(.init(rowNumber: number, place: "", front: "", back: "", problem: .brokenQuoting))
                }
            case .row(let row):
                let front = side(row, mapping.front)
                let back = side(row, mapping.back)

                // Where it would go, for the preview and for filing.
                var names: [String] = []
                var deckName = fallbackDeckName
                if options.destination == .fromFile {
                    names = subjectNames(cell(row, mapping.subject))
                    if let name = Subject.cleanName(cell(row, mapping.deck)) { deckName = name }
                    (names, deckName) = structure.fit(subjectNames: names, deckName: deckName)
                }

                var problem: CSVImportPlan.Reason?
                if front.isEmpty { problem = .emptyFront } else if back.isEmpty { problem = .emptyBack }

                if plan.preview.count < 5 {
                    let place: String
                    switch options.destination {
                    case .fromFile: place = (names + [deckName]).joined(separator: SubjectPath.separator)
                    case .existingDeck: place = existingDeck.map { SubjectPath.text(for: $0, in: library.subjects) } ?? ""
                    case .newDeck: place = newDeckForSingle?.name ?? ""
                    }
                    plan.preview.append(.init(rowNumber: row.number, place: place, front: front, back: back, problem: problem))
                }
                if let problem {
                    plan.skipped.append(.init(rowNumber: row.number, reason: problem))
                    continue
                }

                let card = Card(front: front, back: back)
                switch options.destination {
                case .fromFile:
                    let index = structure.deckIndex(subjectNames: names, deckName: deckName)
                    structure.append(card, toDeckAt: index)
                case .existingDeck:
                    if options.skipDuplicates, existingKeys.contains(key(front, back)) {
                        plan.duplicateCount += 1
                    } else {
                        singleCards.append(card)
                    }
                case .newDeck:
                    singleCards.append(card)
                }
            }
        }

        switch options.destination {
        case .existingDeck(let id):
            if existingDeck != nil, !singleCards.isEmpty { plan.additions = [.init(deckID: id, cards: singleCards)] }
        case .newDeck:
            if var deck = newDeckForSingle, !singleCards.isEmpty {
                deck.cards = singleCards
                plan.newDecks = [deck]
            }
        case .fromFile:
            plan.newSubjects = structure.subjects
            plan.newDecks = structure.decks
        }
        return plan
    }

    private static func key(_ front: String, _ back: String) -> String { "\(front)\u{1F}\(back)" }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// Makes the subjects and decks an import names, once each, in order of first appearance, under the subject
/// the import started from. Shared by the CSV and Anki imports so they nest the same way.
struct ImportStructure {
    /// Parents come before the subjects inside them.
    private(set) var subjects: [Subject] = []
    private(set) var decks: [Deck] = []
    let context: Subject.ID?
    /// How many subject levels can still be made (three, less the depth of the context).
    let levelsAvailable: Int

    private var subjectIDs: [[String]: Subject.ID] = [:]
    private var deckIndexes: [String: Int] = [:]

    init(library: Library, context: Subject.ID?) {
        let tree = SubjectTree(library.subjects)
        self.context = context.flatMap { tree.subject($0) }?.id
        let depth = self.context.flatMap { tree.depth(of: $0) } ?? 0
        levelsAvailable = max(0, Subject.maxDepth - depth)
    }

    /// Names deeper than subjects can go join the deck's name ("D - E - Verbs").
    func fit(subjectNames names: [String], deckName: String) -> (names: [String], deckName: String) {
        guard names.count > levelsAvailable else { return (names, deckName) }
        let overflow = Array(names[levelsAvailable...])
        return (Array(names[..<levelsAvailable]), (overflow + [deckName]).joined(separator: " - "))
    }

    /// The index of the deck with this name under these subjects, made if it isn't there yet. `subjectNames`
    /// must already fit (see `fit`).
    mutating func deckIndex(subjectNames: [String], deckName: String) -> Int {
        let owner = subjectID(for: subjectNames)
        let key = "\(owner?.uuidString ?? "-")|\(deckName)"
        if let index = deckIndexes[key] { return index }
        deckIndexes[key] = decks.count
        decks.append(Deck(name: deckName, subjectID: owner))
        return decks.count - 1
    }

    mutating func append(_ card: Card, toDeckAt index: Int) {
        decks[index].cards.append(card)
    }

    private mutating func subjectID(for names: [String]) -> Subject.ID? {
        var parent = context
        for end in names.indices {
            let path = Array(names[...end])
            if let known = subjectIDs[path] {
                parent = known
                continue
            }
            let subject = Subject(name: names[end], parentID: parent)
            subjects.append(subject)
            subjectIDs[path] = subject.id
            parent = subject.id
        }
        return parent
    }
}

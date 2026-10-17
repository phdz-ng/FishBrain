import Foundation

/// What an export covers: one deck, a subject with everything inside it, or the whole library.
enum ExportTarget: Equatable, Hashable, Identifiable, Sendable {
    case deck(Deck.ID)
    case subject(Subject.ID)
    case library

    var id: String {
        switch self {
        case .deck(let id): "deck-\(id.uuidString)"
        case .subject(let id): "subject-\(id.uuidString)"
        case .library: "library"
        }
    }
}

extension ExportTarget {
    /// What File ▸ Export… covers: the open subject, else the open deck, else the whole library.
    static func current(subjectID: Subject.ID?, deckID: Deck.ID?) -> ExportTarget {
        if let subjectID { return .subject(subjectID) }
        if let deckID { return .deck(deckID) }
        return .library
    }
}

/// The file formats an export can write.
enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, anki

    var id: String { rawValue }

    var title: String {
        switch self {
        case .csv: "CSV spreadsheet"
        case .anki: "Anki package"
        }
    }

    var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .anki: "apkg"
        }
    }

    var summary: String {
        switch self {
        case .csv: "Opens in Numbers, Excel and Google Sheets, and imports into most card apps. Text only."
        case .anki: "Opens in Anki on Mac, iPhone, Android and the web. Keeps pictures."
        }
    }

    var isAvailable: Bool { true }
}

struct CSVExportOptions: Equatable, Sendable {
    var delimiter: CSVDelimiter = .comma
    /// A first row naming the columns.
    var includesHeader = true
    /// Deck and Subject columns after Front and Back, so the file can rebuild where cards sat. Always on
    /// for a subject or the library, since the file would be a heap of cards without them.
    var includesStructure = false
}

/// One deck in the sheet's list of what is included.
struct ExportDeckRow: Equatable, Identifiable, Sendable {
    var id: Deck.ID
    var name: String
    /// The subjects between the exported subject and the deck ("Grammar"), or empty when the deck sits
    /// right in it (or loose).
    var path: String
    var cardCount: Int
}

/// What the sheet asks for, and what it has to say about it. Pure, so the rules are tested without a window.
struct ExportDraft: Equatable, Sendable {
    var target: ExportTarget
    var format: ExportFormat = .csv
    var options = CSVExportOptions()
    /// Decks the user unticked.
    var excluded: Set<Deck.ID> = []

    init(target: ExportTarget) { self.target = target }

    /// The options that apply to this target: a subject and the library always carry the structure.
    var effectiveOptions: CSVExportOptions {
        var result = options
        if deckID == nil { result.includesStructure = true }
        return result
    }

    private var deckID: Deck.ID? {
        if case .deck(let id) = target { return id }
        return nil
    }

    /// Whether the structure columns can be switched (only for one deck).
    var structureIsOptional: Bool { deckID != nil }

    /// Every deck the target covers, in the order the outline lists them.
    func allDecks(subjects: [Subject], decks: [Deck]) -> [Deck] {
        LibraryExport.decks(for: target, subjects: subjects, decks: decks)
    }

    /// The decks that will be written.
    func includedDecks(subjects: [Subject], decks: [Deck]) -> [Deck] {
        allDecks(subjects: subjects, decks: decks).filter { !excluded.contains($0.id) }
    }

    func rows(subjects: [Subject], decks: [Deck]) -> [ExportDeckRow] {
        LibraryExport.rows(for: target, subjects: subjects, decks: decks)
    }

    func cardCount(subjects: [Subject], decks: [Deck]) -> Int {
        includedDecks(subjects: subjects, decks: decks).reduce(0) { $0 + $1.cards.count }
    }

    /// Why Export… can't go ahead, or nil when it can.
    func unavailableReason(subjects: [Subject], decks: [Deck]) -> String? {
        let all = allDecks(subjects: subjects, decks: decks)
        switch target {
        case .deck:
            if all.first?.cards.isEmpty ?? true { return "This deck has no cards yet." }
        case .subject:
            if all.isEmpty { return "There are no decks in this subject yet." }
            if all.allSatisfy({ $0.cards.isEmpty }) { return "There are no cards in this subject yet." }
        case .library:
            if all.allSatisfy({ $0.cards.isEmpty }) { return "There are no cards to export yet." }
        }
        if cardCount(subjects: subjects, decks: decks) == 0 { return "Tick at least one deck that has cards." }
        return nil
    }
}

struct CSVExport: Equatable, Sendable {
    /// The file's bytes: UTF-8 with a byte-order mark, so Excel reads accents correctly.
    var data: Data
    var cardCount: Int
    var deckCount: Int
    /// Pictures on the included cards, which a CSV file can't hold.
    var leftOutPictures: Int
}

enum LibraryExport {
    static let looseSubjectColumn = ""

    // MARK: Which decks

    /// The decks a target covers, in outline order: a subject's sub-subjects first, then its own decks; the
    /// library lists subjects top to bottom, then the loose decks (as the sidebar does).
    static func decks(for target: ExportTarget, subjects: [Subject], decks: [Deck]) -> [Deck] {
        let tree = SubjectTree(subjects)
        switch target {
        case .deck(let id):
            return decks.first { $0.id == id }.map { [$0] } ?? []
        case .subject(let id):
            guard tree.subject(id) != nil else { return [] }
            return tree.decksInOutlineOrder(of: id, among: decks)
        case .library:
            let known = Set(subjects.map(\.id))
            var result: [Deck] = []
            var seen = Set<Deck.ID>()
            for top in subjects where top.parentID == nil || !known.contains(top.parentID!) {
                for deck in tree.decksInOutlineOrder(of: top.id, among: decks) where seen.insert(deck.id).inserted {
                    result.append(deck)
                }
            }
            for deck in decks where !seen.contains(deck.id) { result.append(deck) }
            return result
        }
    }

    static func rows(for target: ExportTarget, subjects: [Subject], decks: [Deck]) -> [ExportDeckRow] {
        let root: Subject.ID? = { if case .subject(let id) = target { id } else { nil } }()
        return Self.decks(for: target, subjects: subjects, decks: decks).map { deck in
            var names = subjectNames(of: deck, root: root, subjects: subjects)
            // The exported subject itself is the heading; the row shows only what lies between.
            if root != nil, !names.isEmpty { names.removeFirst() }
            return ExportDeckRow(id: deck.id, name: deck.name, path: names.joined(separator: SubjectPath.separator), cardCount: deck.cards.count)
        }
    }

    /// The subjects a deck is inside, outermost first, starting at `root` when it is given (so exporting
    /// "Spanish" writes "Spanish › Grammar", not whatever Spanish itself sits in).
    static func subjectNames(of deck: Deck, root: Subject.ID?, subjects: [Subject]) -> [String] {
        guard let subjectID = deck.subjectID else { return [] }
        let tree = SubjectTree(subjects)
        guard let subject = tree.subject(subjectID) else { return [] }
        var chain = Array(tree.ancestors(of: subjectID).reversed()) + [subject]
        if let root, let index = chain.firstIndex(where: { $0.id == root }) { chain.removeFirst(index) }
        return chain.map(\.name)
    }

    // MARK: Writing

    /// "Spanish.csv": the deck's or subject's name, without characters a file name can't hold.
    static func suggestedFileName(target: ExportTarget, subjects: [Subject], decks: [Deck], format: ExportFormat) -> String {
        let name: String
        switch target {
        case .deck(let id): name = decks.first { $0.id == id }?.name ?? ""
        case .subject(let id): name = subjects.first { $0.id == id }?.name ?? ""
        case .library: name = "FishBrain Library"
        }
        let cleaned = name
            .map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
            .map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (cleaned.isEmpty ? "FishBrain" : cleaned) + "." + format.fileExtension
    }

    /// The CSV for `draft`'s included decks.
    static func csv(for draft: ExportDraft, subjects: [Subject], decks: [Deck]) -> CSVExport {
        let included = draft.includedDecks(subjects: subjects, decks: decks)
        let options = draft.effectiveOptions
        let root: Subject.ID? = { if case .subject(let id) = draft.target { id } else { nil } }()

        var rows: [[String]] = []
        if options.includesHeader {
            rows.append(options.includesStructure ? ["Front", "Back", "Deck", "Subject"] : ["Front", "Back"])
        }
        var cardCount = 0
        var pictures = 0
        for deck in included {
            let subjectPath = subjectNames(of: deck, root: root, subjects: subjects).joined(separator: SubjectPath.separator)
            for card in deck.cards {
                rows.append(options.includesStructure
                    ? [card.front, card.back, deck.name, subjectPath]
                    : [card.front, card.back])
                cardCount += 1
                pictures += (card.frontImage == nil ? 0 : 1) + (card.backImage == nil ? 0 : 1)
            }
        }

        var text = CSVRecords.write(rows, delimiter: options.delimiter)
        if !rows.isEmpty { text += "\r\n" }
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        return CSVExport(data: data, cardCount: cardCount, deckCount: included.count, leftOutPictures: pictures)
    }
}

/// The sentences the sheet and the done screen use.
enum ExportMessage {
    static func pictureNotice(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 picture can’t go in a CSV file." : "\(count) pictures can’t go in a CSV file."
    }

    static func pictureAdvice(_ count: Int) -> String {
        "The cards are exported without \(count == 1 ? "it" : "them"). Choose Anki package to keep \(count == 1 ? "it" : "them")."
    }

    static func summary(cards: Int, decks: Int) -> String {
        let cardText = "\(cards) \(cards == 1 ? "card" : "cards")"
        guard decks != 1 else { return cardText }
        return "\(cardText) · \(decks) decks"
    }

    static func doneTitle(cards: Int) -> String {
        "Exported \(cards) \(cards == 1 ? "card" : "cards")"
    }
}

import Foundation

/// Step 1 of a CSV import, "Build your card", as plain data: which columns are on each side of the card,
/// which side columns are being added to, whether the first row is skipped, and the deck's name. The sheet
/// draws it and the tests drive it; every change that VoiceOver should hear returns what to announce.
struct CSVCardBuilder: Equatable {
    enum Side: Equatable, CaseIterable {
        case front, back

        var title: String { self == .front ? "Front" : "Back" }
        /// "the front", "the back".
        var phrase: String { self == .front ? "the front" : "the back" }
        var other: Side { self == .front ? .back : .front }
    }

    let table: CSVTable
    private(set) var hasHeader: Bool
    private(set) var mapping: CSVColumnMapping
    /// The side a clicked column goes to.
    var activeSide: Side
    /// The new deck's name, or the name for rows without a deck when a deck column is chosen. Shared with
    /// step 2's "Add to a new deck".
    var deckName: String

    init(table: CSVTable, fileName: String) {
        self.table = table
        hasHeader = table.looksLikeHeader
        mapping = Self.guess(table, hasHeader: hasHeader)
        activeSide = .front
        deckName = fileName
        activeSide = Self.openingSide(mapping)
    }

    /// "Spanish verbs.csv" names its deck "Spanish verbs".
    static func deckName(forFile url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    private static func guess(_ table: CSVTable, hasHeader: Bool) -> CSVColumnMapping {
        .detect(header: hasHeader ? table.rows.first?.fields : nil, columnCount: table.columnCount)
    }

    /// Back when the front already has a column, so a pre-filled card is ready for the back's extras.
    private static func openingSide(_ mapping: CSVColumnMapping) -> Side { mapping.front.isEmpty ? .front : .back }

    // MARK: What the step shows

    var columnCount: Int { table.columnCount }
    var titles: [String] { table.columnTitles(hasHeader: hasHeader) }

    func title(_ column: Int) -> String {
        let all = titles
        return column < all.count ? all[column] : "Column \(column + 1)"
    }

    /// The row the first card comes from.
    private var firstCardRow: CSVTable.Row? { hasHeader ? table.rows.dropFirst().first : table.rows.first }

    /// The first card's value in a column, shown under its chip on the card.
    func firstValue(_ column: Int) -> String {
        guard let row = firstCardRow, column < row.fields.count else { return "" }
        return row.fields[column]
    }

    /// Rows that can become cards (the skipped first row isn't one), counting rows whose quoting broke.
    var rowCount: Int { table.rows.count - (hasHeader ? 1 : 0) + table.brokenRecords.count }

    func columns(on side: Side) -> [Int] { side == .front ? mapping.front : mapping.back }

    func side(of column: Int) -> Side? {
        if mapping.front.contains(column) { return .front }
        if mapping.back.contains(column) { return .back }
        return nil
    }

    var deckColumn: Int? { mapping.deck }
    var subjectColumn: Int? { mapping.subject }

    /// A column can be added when it is on neither side and isn't the deck column.
    func canAdd(_ column: Int) -> Bool { column < columnCount && side(of: column) == nil && mapping.deck != column }

    /// "It holds the column names: Word, Meaning, Example…" when the first row is skipped, else
    /// "The first row becomes a card: …".
    var firstRowDetail: String {
        let values = (table.rows.first?.fields ?? []).filter { !$0.isEmpty }
        var text = values.prefix(3).joined(separator: ", ")
        if values.count > 3 { text += "…" }
        return hasHeader ? "It holds the column names: \(text)" : "The first row becomes a card: \(text)"
    }

    var deckNameTitle: String { mapping.deck == nil ? "Deck name" : "Deck name for rows without one" }

    func deckNameDetail(cardCount: Int) -> String {
        if mapping.deck != nil { return "Other rows go to the deck their Deck column names." }
        return cardCount == 1 ? "The card goes to a new deck with this name." : "All \(cardCount) cards go to a new deck with this name."
    }

    /// Why Next is refused, or nil when the card can be made. `needsDeckName` is false when the cards go to
    /// a deck that exists.
    func problem(needsDeckName: Bool = true) -> String? {
        if needsDeckName, Subject.cleanName(deckName) == nil { return "Give the deck a name." }
        if mapping.front.isEmpty { return "Choose a column for the front." }
        if mapping.back.isEmpty { return "Choose a column for the back." }
        return nil
    }

    // MARK: Changes

    /// Adds a column to the end of the active side. Returns what to announce, or nil when it can't be added.
    @discardableResult
    mutating func add(_ column: Int) -> String? {
        guard canAdd(column) else { return nil }
        insert(column, on: activeSide, at: columns(on: activeSide).count)
        return "\(title(column)) added to \(activeSide.phrase)"
    }

    /// Takes a column off the card.
    @discardableResult
    mutating func remove(_ column: Int) -> String? {
        guard let side = side(of: column) else { return nil }
        take(column)
        return "\(title(column)) removed from \(side.phrase)"
    }

    /// Puts a column on the card at a place on a side (a drag, or a column dropped from the file's chips).
    /// `index` counts the side's columns before the move.
    @discardableResult
    mutating func move(_ column: Int, to side: Side, at index: Int) -> String? {
        guard column < columnCount, mapping.deck != column else { return nil }
        var target = index
        if let from = self.side(of: column), from == side, let old = columns(on: side).firstIndex(of: column), old < index {
            target -= 1
        }
        let before = mapping
        take(column)
        insert(column, on: side, at: target)
        guard mapping != before else { return nil }
        return placeAnnouncement(column, on: side)
    }

    /// ⌘← on a chip on the card.
    @discardableResult
    mutating func moveEarlier(_ column: Int) -> String? {
        guard let side = side(of: column), let index = columns(on: side).firstIndex(of: column), index > 0 else { return nil }
        return move(column, to: side, at: index - 1)
    }

    /// ⌘→ on a chip on the card.
    @discardableResult
    mutating func moveLater(_ column: Int) -> String? {
        guard let side = side(of: column), let index = columns(on: side).firstIndex(of: column),
              index < columns(on: side).count - 1 else { return nil }
        return move(column, to: side, at: index + 2)
    }

    /// ⌘⇧← / ⌘⇧→ on a chip on the card: to the end of the other side.
    @discardableResult
    mutating func moveToOtherSide(_ column: Int) -> String? {
        guard let side = side(of: column) else { return nil }
        let other = side.other
        return move(column, to: other, at: columns(on: other).count)
    }

    /// The Deck from a column menu. A column chosen here comes off the card.
    mutating func setDeckColumn(_ column: Int?) {
        if let column { take(column) }
        mapping.deck = column
    }

    mutating func setSubjectColumn(_ column: Int?) { mapping.subject = column }

    /// Skip the first row: names the columns from it (or not) and guesses the card again.
    mutating func setSkipsFirstRow(_ on: Bool) {
        hasHeader = on
        mapping = Self.guess(table, hasHeader: on)
        activeSide = Self.openingSide(mapping)
    }

    private mutating func take(_ column: Int) {
        mapping.front.removeAll { $0 == column }
        mapping.back.removeAll { $0 == column }
    }

    private mutating func insert(_ column: Int, on side: Side, at index: Int) {
        switch side {
        case .front: mapping.front.insert(column, at: min(max(index, 0), mapping.front.count))
        case .back: mapping.back.insert(column, at: min(max(index, 0), mapping.back.count))
        }
    }

    private func placeAnnouncement(_ column: Int, on side: Side) -> String {
        let list = columns(on: side)
        let place = (list.firstIndex(of: column) ?? 0) + 1
        if list.count == 1 { return "\(title(column)) moved to \(side.phrase)" }
        return "\(title(column)) moved to \(side.phrase), \(place) of \(list.count)"
    }

    // MARK: VoiceOver

    /// "Front, 1 column, Word. Adding here."
    func areaLabel(_ side: Side) -> String {
        let list = columns(on: side)
        var text: String
        switch list.count {
        case 0: text = "\(side.title), no columns."
        case 1: text = "\(side.title), 1 column, \(title(list[0]))."
        default: text = "\(side.title), \(list.count) columns, \(list.map(title).joined(separator: ", "))."
        }
        if side == activeSide { text += " Adding here." }
        return text
    }

    /// "Add Meaning to the back", or "Meaning, already on the card".
    func columnChipLabel(_ column: Int) -> String {
        if mapping.deck == column { return "\(title(column)), used for the deck" }
        if side(of: column) != nil { return "\(title(column)), already on the card" }
        return "Add \(title(column)) to \(activeSide.phrase)"
    }

    /// "Meaning on the back, first value: to speak. Remove."
    func cardChipLabel(_ column: Int) -> String {
        let side = side(of: column) ?? activeSide
        let value = firstValue(column)
        let first = value.isEmpty ? "no first value" : "first value: \(value)"
        return "\(title(column)) on \(side.phrase), \(first). Remove."
    }
}

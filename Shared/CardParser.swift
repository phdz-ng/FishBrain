import Foundation

struct ParsedCard: Equatable, Sendable {
    var front: String
    var back: String
}

struct CardParseResult: Equatable, Sendable {
    var cards: [ParsedCard]
    /// Non-blank lines that could not be turned into a card.
    var skippedLines: Int
}

/// Turns pasted (or imported) text into cards: one card per record, front and back separated by a
/// tab or a comma.
///
/// - A line containing a tab is split on tabs (what spreadsheets put on the clipboard), so commas
///   in the text are left alone; otherwise it is split on commas (or semicolons, for a file that
///   uses them).
/// - Fields may be quoted (`"hola, amigo", "hello, friend"`); `""` inside quotes is a literal quote.
///   A quoted field may hold a line break. A quote in the middle of an unquoted field is just a
///   character.
/// - Whitespace around fields is trimmed. Columns after the second are ignored.
/// - Blank lines are ignored. Records with one field, an empty front or back, or broken quoting are
///   skipped and counted.
/// - A first line of "Front, Back" (any case) is treated as a header and ignored.
enum CardParser {
    /// `isFile` is for a file's text, where the separator is found from the file (a European Excel writes
    /// `;`). A pasted list keeps commas only, so a semicolon in a sentence isn't taken for a separator.
    static func parse(_ text: String, isFile: Bool = false) -> CardParseResult {
        let fileDelimiter: Character = isFile ? CSVRecords.detectDelimiter(text).character : ","
        let records = CSVRecords.parse(text) { line in
            CSVRecords.hasUnquotedTab(line) ? "\t" : fileDelimiter
        }

        var cards: [ParsedCard] = []
        var skipped = 0
        for (index, record) in records.enumerated() {
            guard case .fields(let fields) = record, fields.count >= 2 else {
                skipped += 1
                continue
            }
            let (front, back) = (fields[0], fields[1])

            if index == 0, front.lowercased() == "front", back.lowercased() == "back" {
                continue
            }
            guard !front.isEmpty, !back.isEmpty else {
                skipped += 1
                continue
            }
            cards.append(ParsedCard(front: front, back: back))
        }
        return CardParseResult(cards: cards, skippedLines: skipped)
    }
}

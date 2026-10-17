import Foundation

/// How fields are separated in a CSV-like file.
enum CSVDelimiter: String, CaseIterable, Sendable {
    case comma, semicolon, tab

    var character: Character {
        switch self {
        case .comma: ","
        case .semicolon: ";"
        case .tab: "\t"
        }
    }

    var displayName: String {
        switch self {
        case .comma: "Comma"
        case .semicolon: "Semicolon"
        case .tab: "Tab"
        }
    }
}

/// Reads and writes CSV as records (RFC 4180), not lines: a quoted field may hold commas, quotes (`""`)
/// and line breaks, so a card with a line break in it survives a round trip.
///
/// Leniency, because the files come from spreadsheets and hand edits:
/// - Spaces around a field are trimmed, quoted or not.
/// - A quote in the middle of an unquoted field is just a character.
/// - A record whose quoting is broken (never closed, or text after the closing quote) is reported as
///   broken and only its first line is skipped, so one bad line can't swallow the file.
/// - Blank lines are ignored; `\n`, `\r\n` and `\r` all end a record.
enum CSVRecords {
    enum Record: Equatable, Sendable {
        case fields([String])
        case broken
    }

    /// Reads every record. `delimiterForRecord` is given the record's first line (trimmed) and returns the
    /// character that separates its fields, so a caller can choose per record (a line with a tab is
    /// tab-separated, as spreadsheets paste it) or per file.
    static func parse(_ text: String, delimiterForRecord: ([Character]) -> Character) -> [Record] {
        let chars = Array(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
        var records: [Record] = []
        var i = 0
        while i < chars.count {
            let lineEnd = endOfLine(chars, from: i)
            let line = trimmed(chars[i..<lineEnd])
            if line.isEmpty {
                i = min(lineEnd + 1, chars.count)
                continue
            }
            let delimiter = delimiterForRecord(line)
            switch scanRecord(chars, from: i, delimiter: delimiter) {
            case .fields(let fields, let next):
                records.append(.fields(fields))
                i = next
            case .broken:
                records.append(.broken)
                i = min(lineEnd + 1, chars.count)
            }
        }
        return records
    }

    /// Reads the whole file with one separator. `nil` finds it from the first line.
    static func parse(_ text: String, delimiter: CSVDelimiter? = nil) -> (records: [Record], delimiter: CSVDelimiter) {
        let chosen = delimiter ?? detectDelimiter(text)
        return (parse(text) { _ in chosen.character }, chosen)
    }

    /// Which separator a file uses: looks at its first records and counts how many hold each of tab,
    /// comma and semicolon outside quotes. Tab wins a tie (what a spreadsheet paste is), then comma, so a
    /// semicolon in a sentence of a comma file can't turn it into a semicolon file.
    static func detectDelimiter(_ text: String) -> CSVDelimiter {
        let chars = Array(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
        let records = separators(in: chars, maxRecords: 25)
        let tabs = records.filter { $0.contains("\t") }.count
        let commas = records.filter { $0.contains(",") }.count
        let semicolons = records.filter { $0.contains(";") }.count
        if tabs > 0, tabs >= commas, tabs >= semicolons { return .tab }
        return semicolons > commas ? .semicolon : .comma
    }

    /// Whether a line holds a tab outside quotes, which is how a spreadsheet paste is told from text that
    /// merely contains a tab.
    static func hasUnquotedTab(_ line: [Character]) -> Bool {
        separators(in: line, maxRecords: 1).first?.contains("\t") ?? false
    }

    /// For each record (up to `maxRecords`, blank ones skipped): the separators found outside quotes. A
    /// quote opens a quoted field only at the start of a field, so `5" pipe` is plain text.
    private static func separators(in chars: [Character], maxRecords: Int) -> [Set<Character>] {
        var records: [Set<Character>] = []
        var found: Set<Character> = []
        var hasContent = false
        var inQuotes = false
        var justClosed = false
        var atFieldStart = true

        func endRecord() {
            if hasContent { records.append(found) }
            found = []
            hasContent = false
            atFieldStart = true
            justClosed = false
        }

        for character in chars {
            if inQuotes {
                if character == "\"" { inQuotes = false; justClosed = true }
                continue
            }
            switch character {
            case "\"":
                hasContent = true
                if justClosed { inQuotes = true; justClosed = false } // `""` inside a quoted field
                else if atFieldStart { inQuotes = true; atFieldStart = false }
                else { atFieldStart = false }
                continue
            case "\t", ",", ";":
                hasContent = true
                found.insert(character)
                atFieldStart = true
            case " ":
                break
            default:
                if character.isNewline {
                    endRecord()
                    if records.count >= maxRecords { return records }
                } else {
                    hasContent = true
                    atFieldStart = false
                }
            }
            justClosed = false
        }
        endRecord()
        return records
    }

    // MARK: Writing

    /// Records joined with CRLF (what spreadsheets expect), a field quoted when it holds the separator, a
    /// quote or a line break.
    static func write(_ rows: [[String]], delimiter: CSVDelimiter = .comma) -> String {
        rows.map { row in row.map(escape).joined(separator: String(delimiter.character)) }
            .joined(separator: "\r\n")
    }

    static func escape(_ field: String) -> String {
        // Every separator is quoted, not just the one in use, so the file's own separator is the only one
        // outside quotes and a reader can tell which it is.
        let needsQuotes = field.contains { $0 == "," || $0 == ";" || $0 == "\t" || $0 == "\"" || $0.isNewline }
            || field.first?.isWhitespace == true || field.last?.isWhitespace == true
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Scanning

    private enum Scan {
        case fields([String], next: Int)
        case broken
    }

    private static func endOfLine(_ chars: [Character], from start: Int) -> Int {
        var i = start
        while i < chars.count, !chars[i].isNewline { i += 1 }
        return i
    }

    private static func trimmed(_ slice: ArraySlice<Character>) -> [Character] {
        var slice = slice
        while let first = slice.first, first.isWhitespace { slice.removeFirst() }
        while let last = slice.last, last.isWhitespace { slice.removeLast() }
        return Array(slice)
    }

    private static func trim(_ field: String) -> String {
        field.trimmingCharacters(in: .whitespaces)
    }

    private static func scanRecord(_ chars: [Character], from start: Int, delimiter: Character) -> Scan {
        var i = start
        var fields: [String] = []

        func skipSpaces() {
            while i < chars.count, chars[i].isWhitespace, !chars[i].isNewline, chars[i] != delimiter { i += 1 }
        }

        while true {
            skipSpaces()
            if i < chars.count, chars[i] == "\"" {
                i += 1
                var field = ""
                var closed = false
                while i < chars.count {
                    if chars[i] == "\"" {
                        if i + 1 < chars.count, chars[i + 1] == "\"" {
                            field.append("\"")
                            i += 2
                            continue
                        }
                        closed = true
                        i += 1
                        break
                    }
                    field.append(chars[i])
                    i += 1
                }
                guard closed else { return .broken }
                skipSpaces()
                guard i == chars.count || chars[i].isNewline || chars[i] == delimiter else { return .broken }
                fields.append(trim(field))
            } else {
                var field = ""
                while i < chars.count, chars[i] != delimiter, !chars[i].isNewline {
                    field.append(chars[i])
                    i += 1
                }
                fields.append(trim(field))
            }

            if i >= chars.count { return .fields(fields, next: i) }
            if chars[i].isNewline { return .fields(fields, next: i + 1) }
            i += 1 // the delimiter
            if i >= chars.count || chars[i].isNewline {
                fields.append("") // trailing delimiter
                return .fields(fields, next: min(i + 1, chars.count))
            }
        }
    }
}

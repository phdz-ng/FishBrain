import Foundation

/// How the imported file's bytes were interpreted.
enum TextEncoding: Equatable, Sendable {
    case utf8
    case utf16
    /// Not valid UTF-8, so read as Windows Latin-1 (what older Excel exports use).
    case windowsLatin1
}

struct CardImport: Equatable, Sendable {
    var cards: [ParsedCard]
    var skippedLines: Int
    var encoding: TextEncoding
}

enum ImportFailure: Error, Equatable, Sendable {
    case unreadable(String)
    case tooLarge(bytes: Int, limit: Int)
    case emptyFile
    case notTextFile
    case noCards(skippedLines: Int)
}

/// Reads a CSV/TSV/text file into cards with the same parser as Paste Cards.
enum CardImporter {
    static let maxBytes = 10_000_000

    /// Opens the file with security-scoped access (needed inside the sandbox for files the user
    /// picked) and imports it.
    static func read(contentsOf url: URL, maxBytes: Int = CardImporter.maxBytes) -> Result<CardImport, ImportFailure> {
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

    static func read(_ data: Data, maxBytes: Int = CardImporter.maxBytes) -> Result<CardImport, ImportFailure> {
        if data.count > maxBytes { return .failure(.tooLarge(bytes: data.count, limit: maxBytes)) }
        if data.isEmpty { return .failure(.emptyFile) }
        guard let (text, encoding) = decode(data) else { return .failure(.notTextFile) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failure(.emptyFile) }

        let parsed = CardParser.parse(text, isFile: true)
        guard !parsed.cards.isEmpty else { return .failure(.noCards(skippedLines: parsed.skippedLines)) }
        return .success(CardImport(cards: parsed.cards, skippedLines: parsed.skippedLines, encoding: encoding))
    }

    /// A byte-order mark decides; otherwise UTF-8 if the bytes are valid UTF-8, else Windows
    /// Latin-1. Data containing NUL bytes (and no UTF-16 mark) is treated as not text.
    static func decode(_ data: Data) -> (String, TextEncoding)? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16).map { ($0, .utf16) }
        }
        if data.prefix(8192).contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if let text = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) {
            return (text, .windowsLatin1)
        }
        return nil
    }
}

/// Wording for the result of an import.
enum ImportMessage {
    struct Notice: Equatable, Sendable {
        var title: String
        var message: String
    }

    static func success(_ result: CardImport, deckName: String) -> Notice {
        let count = result.cards.count
        var lines = ["Added to “\(deckName)”."]
        if result.skippedLines > 0 {
            let n = result.skippedLines
            lines.append("\(n) \(n == 1 ? "line was" : "lines were") skipped because \(n == 1 ? "it" : "they") didn't have both a front and a back.")
        }
        if result.encoding == .windowsLatin1 {
            lines.append("The file isn't UTF-8, so it was read as Windows Latin-1. If accented letters look wrong, save the file as UTF-8 and import it again.")
        }
        return Notice(title: "Imported \(count) \(count == 1 ? "card" : "cards")", message: lines.joined(separator: "\n"))
    }

    static func failure(_ failure: ImportFailure) -> Notice {
        let title = "Nothing was imported"
        switch failure {
        case .unreadable(let reason):
            return Notice(title: title, message: "The file couldn't be read: \(reason)")
        case .tooLarge(let bytes, let limit):
            let format = ByteCountFormatStyle(style: .file)
            return Notice(title: title, message: "The file is \(bytes.formatted(format)), which is over the \(limit.formatted(format)) limit.")
        case .emptyFile:
            return Notice(title: title, message: "The file is empty.")
        case .notTextFile:
            return Notice(title: title, message: "This doesn't look like a text file. Choose a .csv, .tsv or .txt file. If it came from Excel or Numbers, export it as CSV (UTF-8).")
        case .noCards(let skipped):
            let detail = skipped > 0
                ? "None of the \(skipped) \(skipped == 1 ? "line" : "lines") had both a front and a back."
                : "No lines were found."
            return Notice(title: title, message: "\(detail) Each line needs a front and a back separated by a comma or a tab.")
        }
    }
}

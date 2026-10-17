import Foundation
import OSLog

/// Reads and writes the deck library as JSON. Used by the app (read/write) and the widget (read).
struct DeckStorage: Sendable {
    /// 2: cards can carry pictures. 3: the library has subjects, and decks say which one they are in.
    /// An older build that opened a newer file would save it back without them, so it refuses a newer
    /// version instead. Version 1 and 2 files load unchanged, with no subjects.
    static let currentVersion = 3
    static let fileName = "decks.json"

    enum StorageError: Error {
        case unsupportedVersion(Int)
    }

    /// On-disk envelope, so the format can evolve without breaking old files.
    private struct Envelope: Codable {
        var version: Int
        /// Missing in version 1 and 2 files.
        var subjects: [Subject]?
        var decks: [Deck]
    }

    private static let logger = Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "storage")

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) {
        self.directory = directory
    }

    static func shared() -> DeckStorage {
        DeckStorage(directory: AppGroup.storageDirectory())
    }

    /// The decks, flat and in order. Never throws or crashes: a missing file yields no decks, and an
    /// unreadable file is moved aside (so the user's data isn't overwritten) and yields no decks.
    func load() -> [Deck] {
        loadLibrary().decks
    }

    /// The subjects and the decks. A library with a damaged subject tree (a cycle, a missing parent, a
    /// subject too deep) is repaired as it is read, and what was done is logged; no deck or card is
    /// dropped. The repair reaches the file at the next save.
    func loadLibrary() -> Library {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Library()
        } catch {
            Self.logger.error("Could not read \(Self.fileName): \(error.localizedDescription)")
            return Library()
        }

        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version <= Self.currentVersion else {
                throw StorageError.unsupportedVersion(envelope.version)
            }
            let repaired = Library(subjects: envelope.subjects ?? [], decks: envelope.decks).repaired()
            for repair in repaired.repairs {
                Self.logger.error("Repaired \(Self.fileName): \(repair, privacy: .public)")
            }
            return repaired.library
        } catch {
            Self.logger.error("Unreadable \(Self.fileName), moving aside: \(error.localizedDescription)")
            quarantineFile()
            return Library()
        }
    }

    /// Atomic: readers see either the old or the new file, never a partial one.
    func save(_ library: Library) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: Self.currentVersion, subjects: library.subjects, decks: library.decks))
        try data.write(to: fileURL, options: .atomic)
    }

    /// A library with no subjects (a deck-only library, as tests and previews make).
    func save(_ decks: [Deck]) throws {
        try save(Library(decks: decks))
    }

    private func quarantineFile() {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = directory.appendingPathComponent("decks.corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }
}

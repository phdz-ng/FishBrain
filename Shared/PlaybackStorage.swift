import Foundation
import OSLog

/// Per-deck playback state (skips and flips) in `playback.json` in the App Group container, so
/// the app, widget and notch all see the same thing.
struct PlaybackStorage: Sendable {
    static let fileName = "playback.json"
    private static let logger = Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "playback")

    /// Keyed by the deck id's string form, because JSON dictionaries need string keys.
    private struct Envelope: Codable {
        var decks: [String: PlaybackState]
    }

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) {
        self.directory = directory
    }

    static func shared() -> PlaybackStorage {
        PlaybackStorage(directory: AppGroup.storageDirectory())
    }

    /// Never throws: a missing or unreadable file means nobody has skipped or flipped anything.
    func load() -> [Deck.ID: PlaybackState] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            return Dictionary(uniqueKeysWithValues: envelope.decks.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        } catch {
            Self.logger.error("Unreadable \(Self.fileName), starting fresh: \(error.localizedDescription)")
            return [:]
        }
    }

    func save(_ states: [Deck.ID: PlaybackState]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let envelope = Envelope(decks: Dictionary(uniqueKeysWithValues: states.map { ($0.key.uuidString, $0.value) }))
        try encoder.encode(envelope).write(to: fileURL, options: .atomic)
    }

    /// Atomic read-modify-write across processes. The app, the widget and the notch can all change
    /// playback state, so each change re-reads the file under an exclusive lock instead of writing
    /// back a possibly stale copy. Returns the resulting states; the file is only rewritten when
    /// the body actually changed something.
    @discardableResult
    func modify(_ body: (inout [Deck.ID: PlaybackState]) -> Void) throws -> [Deck.ID: PlaybackState] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("playback.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }

        let before = load()
        var after = before
        body(&after)
        if after != before { try save(after) }
        return after
    }

    var modificationDate: Date? {
        try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }
}

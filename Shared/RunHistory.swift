import Foundation
import OSLog

/// One finished Review sprint, as kept in `runs.json`.
struct RunRecord: Codable, Equatable, Sendable {
    struct Grades: Codable, Equatable, Sendable {
        var again = 0
        var hard = 0
        var good = 0
        var easy = 0

        subscript(grade: ReviewGrade) -> Int {
            switch grade {
            case .again: again
            case .hard: hard
            case .good: good
            case .easy: easy
            }
        }

        init(again: Int = 0, hard: Int = 0, good: Int = 0, easy: Int = 0) {
            self.again = again
            self.hard = hard
            self.good = good
            self.easy = easy
        }
    }

    var startedAt: Date
    /// How long it ran: the length it was set for if the clock ran out, otherwise the time it really
    /// ran to the nearest minute (at least one), like `StudySession.end`.
    var minutes: Int
    /// The decks that were in the mix, in the order they first came up in the queue.
    var deckIDs: [Deck.ID]
    /// Grades given.
    var reviewed: Int
    /// Grades given per deck, keyed by the deck id's string form because JSON keys are strings.
    var byDeck: [String: Int]
    var grades: Grades

    /// A run shorter than this says little about how fast you go, so it isn't used for the usual pace.
    static let minimumPaceMinutes = 3

    init(startedAt: Date, minutes: Int, deckIDs: [Deck.ID], reviewed: Int, byDeck: [String: Int], grades: Grades) {
        self.startedAt = startedAt
        self.minutes = max(minutes, 1)
        self.deckIDs = deckIDs
        self.reviewed = reviewed
        self.byDeck = byDeck
        self.grades = grades
    }

    /// What `run` amounts to once it has ended.
    init(run: ReviewRun, deckIDs: [Deck.ID]) {
        let summary = run.summary
        let ranFull = summary.elapsed >= run.duration
        let minutes = ranFull ? run.minutes : min(max(Int((summary.elapsed / 60).rounded()), 1), run.minutes)
        self.init(
            startedAt: run.startedAt, minutes: minutes, deckIDs: deckIDs, reviewed: summary.count,
            byDeck: Dictionary(uniqueKeysWithValues: summary.deckCounts.map { ($0.key.uuidString, $0.value) }),
            grades: Grades(
                again: summary.gradeCounts[.again] ?? 0, hard: summary.gradeCounts[.hard] ?? 0,
                good: summary.gradeCounts[.good] ?? 0, easy: summary.gradeCounts[.easy] ?? 0
            )
        )
    }

    /// Cards a minute.
    var pace: Double { Double(reviewed) / Double(max(minutes, 1)) }

    /// Grades given per deck, by id.
    var deckCounts: [Deck.ID: Int] {
        Dictionary(uniqueKeysWithValues: byDeck.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }
}

/// The last 100 Review sprints and what can be told from them. Pure. There is no "best per mix", because
/// mixes differ; only pace compares one sprint with another.
struct RunHistory: Equatable, Sendable {
    static let keep = 100
    /// The usual pace is the median of this many of the most recent runs that count.
    static let paceWindow = 10
    /// Fewer counted runs than this and there is no usual pace, so no estimate.
    static let paceMinimumRuns = 3

    /// Oldest first.
    private(set) var runs: [RunRecord]

    init(runs: [RunRecord] = []) {
        self.runs = Array(runs.suffix(Self.keep))
    }

    /// Adds a run, dropping the oldest ones past `keep`.
    mutating func append(_ record: RunRecord) {
        runs.append(record)
        if runs.count > Self.keep { runs.removeFirst(runs.count - Self.keep) }
    }

    var isEmpty: Bool { runs.isEmpty }
    var last: RunRecord? { runs.last }

    /// Cards a minute: the median over the last 10 runs of at least 3 minutes. Nil with fewer than 3 such
    /// runs.
    var usualPace: Double? {
        let counted = runs.filter { $0.minutes >= RunRecord.minimumPaceMinutes }.suffix(Self.paceWindow)
        guard counted.count >= Self.paceMinimumRuns else { return nil }
        let paces = counted.map(\.pace).sorted()
        let middle = paces.count / 2
        return paces.count.isMultiple(of: 2) ? (paces[middle - 1] + paces[middle]) / 2 : paces[middle]
    }

    /// Grades given per deck over the most recent `count` runs.
    func deckSplit(recent count: Int = RunHistory.paceWindow) -> [Deck.ID: Int] {
        var split: [Deck.ID: Int] = [:]
        for run in runs.suffix(count) {
            for (id, n) in run.deckCounts { split[id, default: 0] += n }
        }
        return split
    }

    /// What the setup sheet's estimate and the results' chips read.
    var resultsHistory: ReviewResults.History {
        ReviewResults.History(
            usualPace: usualPace, lastCount: last?.reviewed, lastSeconds: last.map { Double($0.minutes) * 60 }
        )
    }
}

/// `runs.json` next to `study.json` in the App Group folder. Never throws on reading and never blocks
/// a sprint: a missing file is no history, and an unreadable one is moved aside, as `decks.json` is,
/// and the history starts again.
struct RunHistoryStorage: Sendable {
    static let fileName = "runs.json"
    private static let logger = Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "runs")

    private struct Envelope: Codable {
        var runs: [RunRecord]
    }

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) {
        self.directory = directory
    }

    static func shared() -> RunHistoryStorage {
        RunHistoryStorage(directory: AppGroup.storageDirectory())
    }

    func load() -> RunHistory {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return RunHistory()
        } catch {
            Self.logger.error("Could not read \(Self.fileName): \(error.localizedDescription)")
            return RunHistory()
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return RunHistory(runs: try decoder.decode(Envelope.self, from: data).runs)
        } catch {
            Self.logger.error("Unreadable \(Self.fileName), moving aside: \(error.localizedDescription)")
            quarantineFile()
            return RunHistory()
        }
    }

    func save(_ history: RunHistory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Envelope(runs: history.runs)).write(to: fileURL, options: .atomic)
    }

    /// Atomic read-modify-write across processes, like the study log: each change re-reads the file
    /// under an exclusive lock, so two writers lose nothing.
    @discardableResult
    func modify(_ body: (inout RunHistory) -> Void) throws -> RunHistory {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("runs.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }

        let before = load()
        var after = before
        body(&after)
        if after != before || !FileManager.default.fileExists(atPath: fileURL.path) { try save(after) }
        return after
    }

    @discardableResult
    func append(_ record: RunRecord) throws -> RunHistory {
        try modify { $0.append(record) }
    }

    var modificationDate: Date? {
        try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    private func quarantineFile() {
        let stamp = Int(Date().timeIntervalSince1970)
        var backup = directory.appendingPathComponent("runs.corrupt-\(stamp).json")
        // Two unreadable files in one second shouldn't overwrite each other.
        var n = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = directory.appendingPathComponent("runs.corrupt-\(stamp)-\(n).json")
            n += 1
        }
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }
}

/// App-side view of the sprint history. Recording saves at once and publishes; `refresh()` picks up a
/// change another process wrote.
@MainActor
final class RunHistoryStore: ObservableObject {
    @Published private(set) var history: RunHistory

    private let storage: RunHistoryStorage
    private var lastSeenModification: Date?
    private let logger = Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "runs")

    init(storage: RunHistoryStorage = .shared()) {
        self.storage = storage
        self.history = storage.load()
        self.lastSeenModification = storage.modificationDate
    }

    func refresh() {
        let modified = storage.modificationDate
        guard modified != lastSeenModification else { return }
        lastSeenModification = modified
        let loaded = storage.load()
        if loaded != history { history = loaded }
    }

    /// Saves a finished sprint. A failure is logged and never stops anything: the sprint is over.
    func record(_ run: RunRecord) {
        do {
            let updated = try storage.append(run)
            lastSeenModification = storage.modificationDate
            if updated != history { history = updated }
        } catch {
            logger.error("Could not save a sprint: \(error.localizedDescription)")
            // Still shown for this session.
            var local = history
            local.append(run)
            history = local
        }
    }
}

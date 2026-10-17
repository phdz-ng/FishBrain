import Foundation

/// A timed study session: for a few minutes the cards rotate every 30 seconds, and the notch counts
/// how many you got through. One session at a time, shared by every display.
///
/// The session keeps its own rotation (its own skips and flips), counted from the moment it starts,
/// so the normal rotation the widget and the app follow is left alone and picks up again at the end.
struct StudySession: Codable, Equatable, Sendable {
    /// A session in progress.
    struct Active: Codable, Equatable, Sendable {
        var startedAt: Date
        var minutes: Int
        var deckID: UUID
        var playback: PlaybackState
        /// Rotation positions whose card was flipped to its answer: each card counts once.
        var reviewedPositions: Set<Int> = []

        var duration: TimeInterval { Double(minutes) * 60 }
        var endsAt: Date { startedAt.addingTimeInterval(duration) }
        var reviewed: Int { reviewedPositions.count }
        var scheduler: CardScheduler {
            CardScheduler(interval: StudySession.rotationInterval, origin: startedAt.timeIntervalSince1970)
        }

        /// Time left, from the clock: right after sleep and wake, never negative.
        func remaining(at now: Date) -> TimeInterval { max(endsAt.timeIntervalSince(now), 0) }

        /// 0 at the start, 1 at the end.
        func progress(at now: Date) -> Double {
            min(max(now.timeIntervalSince(startedAt) / duration, 0), 1)
        }
    }

    /// How a session went: shown for a few seconds when it ends, and kept as "Last: 22 cards".
    struct Result: Codable, Equatable, Sendable {
        var reviewed: Int
        var minutes: Int
        var endedAt: Date

        /// "22 cards in 15 min"
        var text: String { "\(reviewed) \(reviewed == 1 ? "card" : "cards") in \(minutes) min" }
        /// "Last: 22 cards"
        var lastText: String { "Last: \(reviewed) \(reviewed == 1 ? "card" : "cards")" }
    }

    /// Cards rotate this often while a session runs.
    static let rotationInterval: TimeInterval = 30
    static let lengths = [5, 10, 15, 25]
    static let defaultMinutes = 15
    /// How long the recap stays on screen.
    static let recapDuration: TimeInterval = 8

    var active: Active?
    var last: Result?
    var recapUntil: Date?
    /// The length the Start button uses.
    var preferredMinutes = StudySession.defaultMinutes

    /// Starts on the card that is showing now, so the rotation carries on from it.
    mutating func start(deckID: UUID, currentIndex: Int, minutes: Int, at now: Date) {
        let minutes = Self.lengths.contains(minutes) ? minutes : Self.defaultMinutes
        preferredMinutes = minutes
        recapUntil = nil
        // Slot 0 is the session's first 30 seconds, so the offset puts the current card there.
        active = Active(startedAt: now, minutes: minutes, deckID: deckID, playback: PlaybackState(skipOffset: currentIndex))
    }

    /// Ends the session if its time is up. Returns true if it just ended. Called on every refresh, so
    /// a Mac that slept through the end shows the recap on wake, not the old timer.
    @discardableResult
    mutating func expireIfNeeded(at now: Date) -> Bool {
        guard let active, now >= active.endsAt else { return false }
        finish(active, minutes: active.minutes, endedAt: now)
        return true
    }

    /// Ends it early. The recap says how long it really ran, to the nearest minute (at least one).
    mutating func end(at now: Date) {
        guard let active else { return }
        let elapsed = max(now.timeIntervalSince(active.startedAt), 0)
        finish(active, minutes: min(max(Int((elapsed / 60).rounded()), 1), active.minutes), endedAt: now)
    }

    private mutating func finish(_ session: Active, minutes: Int, endedAt: Date) {
        let result = Result(reviewed: session.reviewed, minutes: minutes, endedAt: endedAt)
        last = result
        recapUntil = endedAt.addingTimeInterval(Self.recapDuration)
        active = nil
    }

    /// A Review sprint finished: its result is shown as the recap and kept as "Last: N cards", exactly
    /// where a session's would be, so the notch never needs to know which kind it was.
    mutating func recordFinished(_ result: Result) {
        last = result
        recapUntil = result.endedAt.addingTimeInterval(Self.recapDuration)
    }

    /// The recap, while it is still on screen.
    func recap(at now: Date) -> Result? {
        guard let recapUntil, now < recapUntil else { return nil }
        return last
    }

    /// Turns the shown card over. Returns the card's id when this turned it to the answer, which is
    /// the moment it counts as studied.
    mutating func flip(in deck: Deck, at now: Date) -> Card.ID? {
        guard var session = active else { return nil }
        let scheduler = session.scheduler
        let next = scheduler.flipping(session.playback, in: deck, at: now)
        session.playback = next
        var studied: Card.ID?
        if let card = scheduler.currentCard(in: deck, state: next, at: now), card.isFlipped {
            studied = card.card.id
            session.reviewedPositions.insert(scheduler.position(state: next, at: now))
        }
        active = session
        return studied
    }

    mutating func skip(in deck: Deck, at now: Date) {
        guard var session = active else { return }
        session.playback = session.scheduler.skipping(session.playback, in: deck, at: now)
        active = session
    }
}

/// `session.json`: the session in progress and the last result, so a relaunch carries on. Only the app
/// reads and writes it.
struct SessionStorage: Sendable {
    static let fileName = "session.json"

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) {
        self.directory = directory
    }

    static func shared() -> SessionStorage {
        SessionStorage(directory: AppGroup.storageDirectory())
    }

    /// Never throws: a missing or unreadable file means no session.
    func load() -> StudySession {
        guard let data = try? Data(contentsOf: fileURL) else { return StudySession() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(StudySession.self, from: data)) ?? StudySession()
    }

    func save(_ session: StudySession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(session).write(to: fileURL, options: .atomic)
    }
}

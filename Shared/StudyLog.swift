import Foundation

/// How much was studied on each day: the data behind the streak and the daily goal. A card counts as
/// studied when it is flipped to its answer, and only once per day however often it comes round.
///
/// Only today keeps the ids of the cards (to count each once); earlier days keep just a count and
/// whether the goal was met, so the file stays small however long the streak gets.
struct StudyLog: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable {
        var count = 0
        /// Once a day's goal has been reached it stays reached, even if the goal is raised later.
        var met = false
    }

    /// Keyed by `yyyy-MM-dd` in the calendar in use when the card was studied.
    var days: [String: Day] = [:]
    var todayKey: String?
    var todayCards: Set<UUID> = []

    /// Days kept: a streak this long is plenty, and older days can't change the answer for a living one.
    static let daysKept = 400

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Notes that a card was studied. Returns false if it had already counted today.
    @discardableResult
    mutating func record(cardID: UUID, at date: Date, goal: Int, calendar: Calendar = .current) -> Bool {
        let key = Self.key(for: date, calendar: calendar)
        if todayKey != key {
            // A new day (or the clock moved): yesterday's card ids are no longer needed.
            todayKey = key
            todayCards = []
        }
        guard todayCards.insert(cardID).inserted else { return false }
        var day = days[key] ?? Day()
        day.count += 1
        if day.count >= goal { day.met = true }
        days[key] = day
        prune(before: date, calendar: calendar)
        return true
    }

    private mutating func prune(before date: Date, calendar: Calendar) {
        guard days.count > Self.daysKept,
              let cutoff = calendar.date(byAdding: .day, value: -Self.daysKept, to: date) else { return }
        let cutoffKey = Self.key(for: cutoff, calendar: calendar)
        days = days.filter { $0.key >= cutoffKey }
    }

    func count(on date: Date, calendar: Calendar = .current) -> Int {
        days[Self.key(for: date, calendar: calendar)]?.count ?? 0
    }

    /// Whether the goal was reached on a day. For today it also counts a goal lowered after the
    /// cards were studied.
    func metGoal(on date: Date, goal: Int, now: Date, calendar: Calendar = .current) -> Bool {
        let day = days[Self.key(for: date, calendar: calendar)]
        let isToday = calendar.isDate(date, inSameDayAs: now)
        return (day?.met ?? false) || (isToday && (day?.count ?? 0) >= goal)
    }

    /// Consecutive days with the goal met, ending today, or ending yesterday while today is still
    /// open. Zero once a whole day has been missed.
    func streak(at now: Date, goal: Int, calendar: Calendar = .current) -> Int {
        var day = now
        if !metGoal(on: day, goal: goal, now: now, calendar: calendar) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while metGoal(on: day, goal: goal, now: now, calendar: calendar) {
            streak += 1
            guard streak <= Self.daysKept + 1, let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    func summary(at now: Date, goal: Int, calendar: Calendar = .current) -> StudySummary {
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let week = (0..<7).compactMap { offset -> StudySummary.Dot? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let isToday = calendar.isDate(day, inSameDayAs: now)
            let state: StudySummary.Dot.State
            if metGoal(on: day, goal: goal, now: now, calendar: calendar) {
                state = .met
            } else if day > now && !isToday {
                state = .upcoming
            } else {
                state = .open
            }
            return StudySummary.Dot(state: state, isToday: isToday)
        }
        return StudySummary(
            count: count(on: now, calendar: calendar), goal: goal,
            streak: streak(at: now, goal: goal, calendar: calendar), week: week
        )
    }
}

/// What the notch shows about studying: today's count against the goal, the streak, and this week.
struct StudySummary: Equatable, Sendable {
    struct Dot: Equatable, Sendable {
        enum State: Equatable, Sendable {
            /// The goal was reached that day.
            case met
            /// A day that wasn't (a missed day, or today so far).
            case open
            /// A day still to come this week.
            case upcoming
        }
        var state: State
        var isToday: Bool
    }

    var count: Int
    var goal: Int
    var streak: Int
    /// Seven days, starting on the calendar's first weekday.
    var week: [Dot]

    var goalMetToday: Bool { count >= goal }

    /// "12 days", "1 day", or an invitation when there is no streak yet.
    var streakText: String {
        streak == 0 ? "Start a streak" : "\(streak) \(streak == 1 ? "day" : "days")"
    }

    /// "18 / 30 today": the pill.
    var progressText: String { "\(count) / \(goal) today" }

    /// "18 of 30 today · 12-day streak": the open notch.
    var openLine: String {
        let base = "\(count) of \(goal) today"
        return streak == 0 ? base : base + " · \(streak)-day streak"
    }

    /// Spoken: "12-day streak, 18 of 30 cards today".
    var accessibilityText: String {
        let cards = "\(count) of \(goal) cards today"
        return streak == 0 ? "No streak yet, \(cards)" : "\(streak)-day streak, \(cards)"
    }

    static let sample = StudySummary(
        count: 18, goal: 30, streak: 12,
        week: [.met, .met, .met, .open, .upcoming, .upcoming, .upcoming].enumerated().map {
            Dot(state: $0.element, isToday: $0.offset == 3)
        }
    )
}

/// `study.json` next to `decks.json`, so the widget's flips count too.
struct StudyStorage: Sendable {
    static let fileName = "study.json"

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) {
        self.directory = directory
    }

    static func shared() -> StudyStorage {
        StudyStorage(directory: AppGroup.storageDirectory())
    }

    /// Never throws: a missing or unreadable file means nothing has been studied yet.
    func load() -> StudyLog {
        guard let data = try? Data(contentsOf: fileURL) else { return StudyLog() }
        return (try? JSONDecoder().decode(StudyLog.self, from: data)) ?? StudyLog()
    }

    func save(_ log: StudyLog) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(log).write(to: fileURL, options: .atomic)
    }

    /// Atomic read-modify-write across processes, as `PlaybackStorage.modify` does: the app and the
    /// widget can both record a card, so each change re-reads the file under an exclusive lock.
    @discardableResult
    func modify(_ body: (inout StudyLog) -> Void) throws -> StudyLog {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("study.lock").path, O_CREAT | O_RDWR, 0o644)
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

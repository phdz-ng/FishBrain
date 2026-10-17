import Combine
import Foundation

/// Which kind of study clock is running: the notch's 30-second-rotation session, or a Review sprint.
enum StudyClockKind: Equatable, Sendable {
    case session
    case sprint

    /// What VoiceOver calls it.
    var title: String {
        switch self {
        case .session: "Study session"
        case .sprint: "Review sprint"
        }
    }
}

/// A study clock that is running, whichever kind, in the one shape the notch draws.
struct StudyClockInfo: Equatable, Sendable {
    var kind: StudyClockKind = .session
    var startedAt: Date
    var endsAt: Date
    var minutes: Int
    var reviewed: Int
    /// While a sprint is paused its clock stands still at this moment.
    var pausedAt: Date?

    func remaining(at now: Date) -> TimeInterval { max(endsAt.timeIntervalSince(pausedAt ?? now), 0) }

    func progress(at now: Date) -> Double {
        let length = endsAt.timeIntervalSince(startedAt)
        guard length > 0 else { return 1 }
        return min(max((pausedAt ?? now).timeIntervalSince(startedAt) / length, 0), 1)
    }

    /// "Review sprint, 7:42 left, 17 cards reviewed"
    func accessibilityLabel(at now: Date) -> String {
        "\(kind.title), \(NowShowing.format(seconds: Int(remaining(at: now).rounded(.up)))) left, \(reviewed) cards reviewed"
    }

    /// The open notch's line: "12:40 left · 8 reviewed" for a session, "Sprint · 7:42 left · 17 reviewed" for a sprint.
    func openText(at now: Date) -> String {
        let left = NowShowing.format(seconds: Int(remaining(at: now).rounded(.up)))
        switch kind {
        case .session: return "\(left) left · \(reviewed) reviewed"
        case .sprint: return "Sprint · \(left) left · \(reviewed) reviewed"
        }
    }

    init(
        kind: StudyClockKind = .session, startedAt: Date, endsAt: Date, minutes: Int, reviewed: Int, pausedAt: Date? = nil
    ) {
        self.kind = kind
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.minutes = minutes
        self.reviewed = reviewed
        self.pausedAt = pausedAt
    }

    init(session active: StudySession.Active) {
        self.init(kind: .session, startedAt: active.startedAt, endsAt: active.endsAt, minutes: active.minutes, reviewed: active.reviewed)
    }
}

/// What the notch shows for the study clock: nothing running, one running, or the recap of the one that
/// just ended. The notch reads this one value and never needs to know which kind it was.
enum StudyClockPhase: Equatable, Sendable {
    case idle
    case running(StudyClockInfo)
    case recap(StudySession.Result)
}

/// Owns who is running the study clock, so the notch session and a Review sprint are never running at
/// once. A session lives in `SessionStore`; a sprint lives on the main window and reports here.
///
/// Finishing either kind leaves the same recap (a few seconds) and the same "Last: N cards", because a
/// sprint writes its result where a session's goes.
@MainActor
final class StudyClockGate: ObservableObject {
    /// The sprint in progress, if any.
    @Published private(set) var sprint: StudyClockInfo?

    private let sessions: SessionStore
    private var forwarding: AnyCancellable?

    init(sessions: SessionStore) {
        self.sessions = sessions
        // The notch watches this one object: a session starting, ending or being flipped is a change here too.
        forwarding = sessions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: What is running

    /// Pure: a sprint takes precedence (and, by the gate's rules, a session is never running with it).
    static func phase(session: StudySession, sprint: StudyClockInfo?, at now: Date) -> StudyClockPhase {
        if let sprint { return .running(sprint) }
        if let active = session.active { return .running(StudyClockInfo(session: active)) }
        if let recap = session.recap(at: now) { return .recap(recap) }
        return .idle
    }

    func phase(at now: Date) -> StudyClockPhase {
        Self.phase(session: sessions.session, sprint: sprint, at: now)
    }

    var isSprintRunning: Bool { sprint != nil }

    /// Start session is available only when no clock is running.
    var canStartSession: Bool { sprint == nil && sessions.active == nil }

    // MARK: Starting a sprint

    enum SprintStart: Equatable {
        case allowed
        /// A notch session is running: ask before it is ended.
        case needsConfirmation(StudyClockInfo)
    }

    func requestSprintStart(at now: Date) -> SprintStart {
        guard let active = sessions.active else { return .allowed }
        return .needsConfirmation(StudyClockInfo(session: active))
    }

    /// "12:40 left, 8 cards reviewed. Starting a sprint ends it and keeps its 8 cards."
    static func confirmationText(for info: StudyClockInfo, at now: Date) -> String {
        let left = NowShowing.format(seconds: Int(info.remaining(at: now).rounded(.up)))
        let cards = "\(info.reviewed) \(info.reviewed == 1 ? "card" : "cards")"
        return "\(left) left, \(cards) reviewed. Starting a sprint ends it and keeps its \(cards)."
    }

    /// Ends the notch session as "End session" would: its cards are kept and it leaves its recap.
    func endSessionForSprint(at now: Date) {
        sessions.end(at: now)
    }

    // MARK: A sprint reports in

    /// A sprint began. A session still running (it shouldn't be) is ended first, so two clocks never overlap.
    func sprintStarted(_ info: StudyClockInfo, at now: Date) {
        if sessions.active != nil { sessions.end(at: now) }
        sprint = info
    }

    /// The sprint's clock or count changed (a grade, a pause, a resume).
    func sprintChanged(_ info: StudyClockInfo) {
        guard sprint != nil, sprint != info else { return }
        sprint = info
    }

    /// The sprint is over. Its result becomes the recap and "Last: N cards"; nil (nothing was graded)
    /// leaves what was there.
    func sprintEnded(_ result: StudySession.Result?) {
        sprint = nil
        if let result { sessions.recordFinished(result) }
    }
}

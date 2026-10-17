import Foundation
import OSLog

/// The one study session, shared by every display's notch. Changes save at once and publish, so each
/// notch redraws. Cards flipped to their answer during a session count toward the daily goal like any
/// other flip.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var session: StudySession

    private let storage: SessionStorage
    private let studyStorage: StudyStorage
    private let logger = Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "session")

    init(storage: SessionStorage = .shared(), studyStorage: StudyStorage = .shared()) {
        self.storage = storage
        self.studyStorage = studyStorage
        self.session = storage.load()
    }

    var active: StudySession.Active? { session.active }

    func start(deckID: UUID, currentIndex: Int, minutes: Int, at now: Date = Date()) {
        update { $0.start(deckID: deckID, currentIndex: currentIndex, minutes: minutes, at: now) }
    }

    func end(at now: Date = Date()) {
        update { $0.end(at: now) }
    }

    /// Ends the session if its time has run out. Cheap; the notch calls it on every refresh.
    func expireIfNeeded(at now: Date = Date()) {
        guard let active = session.active, now >= active.endsAt else { return }
        update { $0.expireIfNeeded(at: now) }
    }

    /// A Review sprint ended: its result is the recap and the "Last" result, like a session's.
    func recordFinished(_ result: StudySession.Result) {
        update { $0.recordFinished(result) }
    }

    func setPreferredMinutes(_ minutes: Int) {
        guard StudySession.lengths.contains(minutes), minutes != session.preferredMinutes else { return }
        update { $0.preferredMinutes = minutes }
    }

    func flip(in deck: Deck, at now: Date = Date()) {
        var studied: Card.ID?
        update { studied = $0.flip(in: deck, at: now) }
        guard let studied else { return }
        // Counts toward the streak and the goal, like a flip anywhere else.
        let goal = SettingsStorage(directory: studyStorage.directory).load().dailyGoal
        do {
            try studyStorage.modify { $0.record(cardID: studied, at: now, goal: goal) }
        } catch {
            logger.error("Could not record a studied card: \(error.localizedDescription)")
        }
    }

    func skip(in deck: Deck, at now: Date = Date()) {
        update { $0.skip(in: deck, at: now) }
    }

    private func update(_ change: (inout StudySession) -> Void) {
        var next = session
        change(&next)
        guard next != session else { return }
        session = next
        do {
            try storage.save(next)
        } catch {
            logger.error("Could not save the session: \(error.localizedDescription)")
        }
    }
}

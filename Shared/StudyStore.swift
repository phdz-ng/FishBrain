import Foundation
import OSLog

/// App-side view of the study log. Studying happens in the app, the notch and the widget, which all
/// write `study.json` through `PlaybackActions`; this reads it back and publishes it.
@MainActor
final class StudyStore: ObservableObject {
    @Published private(set) var log: StudyLog

    private let storage: StudyStorage
    private var lastSeenModification: Date?

    init(storage: StudyStorage = .shared()) {
        self.storage = storage
        self.log = storage.load()
        self.lastSeenModification = storage.modificationDate
    }

    /// Cheap: only re-reads the file when something has changed it.
    func refresh() {
        let modified = storage.modificationDate
        guard modified != lastSeenModification else { return }
        lastSeenModification = modified
        let loaded = storage.load()
        if loaded != log { log = loaded }
    }

    /// Counts a card toward today's goal, once per card per day. Learn mode calls this when a card is
    /// turned to its answer; nothing about the card's review changes. Returns false if it had already
    /// counted today (or the log couldn't be written).
    @discardableResult
    func recordStudied(_ cardID: Card.ID, at date: Date, goal: Int, calendar: Calendar = .current) -> Bool {
        var counted = false
        do {
            let updated = try storage.modify { counted = $0.record(cardID: cardID, at: date, goal: goal, calendar: calendar) }
            lastSeenModification = storage.modificationDate
            if updated != log { log = updated }
        } catch {
            Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "study")
                .error("Could not record a studied card: \(error.localizedDescription)")
        }
        return counted
    }

    func summary(at date: Date, goal: Int, calendar: Calendar = .current) -> StudySummary {
        log.summary(at: date, goal: goal, calendar: calendar)
    }
}

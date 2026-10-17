import Foundation
import OSLog
import WidgetKit

/// App-side view of the playback state. Skipping or flipping saves right away and refreshes the
/// widgets; `refresh()` picks up changes another process (the widget or notch) wrote.
@MainActor
final class PlaybackStore: ObservableObject {
    @Published private(set) var states: [Deck.ID: PlaybackState]
    @Published private(set) var lastSaveError: Error?

    private let storage: PlaybackStorage
    private let scheduler: CardScheduler
    private let onSaved: @MainActor () -> Void
    private var lastSeenModification: Date?
    private let logger = Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "playback")

    init(
        storage: PlaybackStorage = .shared(),
        scheduler: CardScheduler = CardScheduler(),
        onSaved: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.storage = storage
        self.scheduler = scheduler
        self.onSaved = onSaved
        self.states = storage.load()
        self.lastSeenModification = storage.modificationDate
    }

    func state(for deckID: Deck.ID) -> PlaybackState {
        states[deckID] ?? PlaybackState()
    }

    func skip(_ deck: Deck, at date: Date = Date()) {
        apply { try PlaybackActions.skip(deck, in: storage, at: date, scheduler: scheduler) }
    }

    func flip(_ deck: Deck, at date: Date = Date()) {
        apply { try PlaybackActions.flip(deck, in: storage, at: date, scheduler: scheduler) }
    }

    func grade(_ grade: ReviewGrade, _ deck: Deck, at date: Date = Date()) {
        apply { try PlaybackActions.grade(grade, deck, in: storage, at: date, scheduler: scheduler) }
    }

    /// A Review sprint grades the cards it picks itself, without moving the rotation.
    func grade(_ grade: ReviewGrade, cardID: Card.ID, in deck: Deck, at date: Date = Date()) {
        apply { try PlaybackActions.grade(grade, cardID: cardID, in: deck, storage: storage, at: date) }
    }

    /// Cheap enough to call every second: it only re-reads the file when it has changed.
    func refresh() {
        let modified = storage.modificationDate
        guard modified != lastSeenModification else { return }
        lastSeenModification = modified
        states = storage.load()
    }

    /// Runs a locked read-modify-write and publishes the result; widgets reload only if it changed.
    private func apply(_ action: () throws -> [Deck.ID: PlaybackState]) {
        do {
            let before = states
            let result = try action()
            states = result
            lastSeenModification = storage.modificationDate
            lastSaveError = nil
            if result != before { onSaved() }
        } catch {
            lastSaveError = error
            logger.error("Save failed: \(error.localizedDescription)")
        }
    }
}

import Foundation
import OSLog

/// Flip and skip, applied to the shared playback file. The app, the widget's buttons and (later)
/// the notch all go through here, so they change the same state the same way.
enum PlaybackActions {
    @discardableResult
    static func flip(
        _ deck: Deck,
        in storage: PlaybackStorage,
        at date: Date = Date(),
        scheduler: CardScheduler = CardScheduler()
    ) throws -> [Deck.ID: PlaybackState] {
        var studied: Card.ID?
        let result = try storage.modify { states in
            let current = states[deck.id] ?? PlaybackState()
            let next = scheduler.flipping(current, in: deck, at: date)
            if next != current { states[deck.id] = next }
            // Turning to the answer counts as studying the card; turning back doesn't.
            if let card = scheduler.currentCard(in: deck, state: next, at: date), card.isFlipped {
                studied = card.card.id
            }
        }
        if let studied { recordStudied(studied, at: date, beside: storage) }
        return result
    }

    /// Counts a card toward today's goal. The log and the goal live next to the playback file, so
    /// the app, the notch and the widget all write to the same place. A failure here never stops the
    /// flip itself.
    private static func recordStudied(_ cardID: Card.ID, at date: Date, beside storage: PlaybackStorage) {
        let goal = SettingsStorage(directory: storage.directory).load().dailyGoal
        do {
            try StudyStorage(directory: storage.directory).modify { $0.record(cardID: cardID, at: date, goal: goal) }
        } catch {
            Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "study")
                .error("Could not record a studied card: \(error.localizedDescription)")
        }
    }

    @discardableResult
    static func skip(
        _ deck: Deck,
        in storage: PlaybackStorage,
        at date: Date = Date(),
        scheduler: CardScheduler = CardScheduler()
    ) throws -> [Deck.ID: PlaybackState] {
        try storage.modify { states in
            let current = states[deck.id] ?? PlaybackState()
            let next = scheduler.skipping(current, in: deck, at: date)
            if next != current { states[deck.id] = next }
        }
    }

    /// Grades the card on show (it has to be turned over to its answer), schedules its next review and
    /// moves on to the next card. A card that isn't showing its answer is left alone, so a second tap
    /// on a grade button can't grade the card that arrived after the first.
    @discardableResult
    static func grade(
        _ grade: ReviewGrade,
        _ deck: Deck,
        in storage: PlaybackStorage,
        at date: Date = Date(),
        scheduler: CardScheduler = CardScheduler()
    ) throws -> [Deck.ID: PlaybackState] {
        try storage.modify { states in
            var state = states[deck.id] ?? PlaybackState()
            guard let shown = scheduler.currentCard(in: deck, state: state, at: date), shown.isFlipped else { return }
            let id = shown.card.id
            state.reviews[id.uuidString] = ReviewScheduler.graded(state.review(for: id), grade, at: date)
            state.flip = nil
            // Drop the schedules of cards that were deleted from the deck.
            let live = Set(deck.cards.map { $0.id.uuidString })
            state.reviews = state.reviews.filter { live.contains($0.key) }
            // A graded card that is still the one on show (every card is, when none are due) has to
            // make way: due cards leave the list by themselves, the rest step on.
            if scheduler.currentCard(in: deck, state: state, at: date)?.card.id == id {
                state.skipOffset += 1
            }
            states[deck.id] = state
        }
    }

    /// Grades a **named** card and schedules it, for the Review sprint, which picks its own cards. It
    /// leaves the skip offset and the flip alone, so a sprint never moves the rotation the widget and
    /// the notch follow, and it needs no flip: grading counts the card toward today's goal like a
    /// flip does. Same locked read-modify-write and pruning of deleted cards' reviews as `grade`.
    /// A card that isn't in `deck` is left alone.
    @discardableResult
    static func grade(
        _ grade: ReviewGrade,
        cardID: Card.ID,
        in deck: Deck,
        storage: PlaybackStorage,
        at date: Date = Date()
    ) throws -> [Deck.ID: PlaybackState] {
        guard deck.cards.contains(where: { $0.id == cardID }) else { return storage.load() }
        let result = try storage.modify { states in
            var state = states[deck.id] ?? PlaybackState()
            state.reviews[cardID.uuidString] = ReviewScheduler.graded(state.review(for: cardID), grade, at: date)
            let live = Set(deck.cards.map { $0.id.uuidString })
            state.reviews = state.reviews.filter { live.contains($0.key) }
            states[deck.id] = state
        }
        recordStudied(cardID, at: date, beside: storage)
        return result
    }

    enum Action { case flip, skip, grade(ReviewGrade) }

    /// What a widget button does: look the deck up by id and apply the action. A deck that no
    /// longer exists (deleted while the widget still showed it) is a no-op. Returns whether
    /// anything was applied.
    @discardableResult
    static func perform(
        _ action: Action,
        deckID: String,
        decks: DeckStorage = .shared(),
        playback: PlaybackStorage = .shared(),
        at date: Date = Date()
    ) throws -> Bool {
        guard let id = UUID(uuidString: deckID), let deck = decks.load().first(where: { $0.id == id }) else { return false }
        switch action {
        case .flip: try flip(deck, in: playback, at: date)
        case .skip: try skip(deck, in: playback, at: date)
        case .grade(let grade): try Self.grade(grade, deck, in: playback, at: date)
        }
        return true
    }
}

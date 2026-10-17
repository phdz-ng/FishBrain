import Foundation

/// A Review sprint on screen: the queue, the run's clock, whether the card is turned over, and what the
/// keys do. Grades go to the shared playback file by card, so the widget and the notch rotation never
/// move; the queue was built when the sprint started and holds only ids.
@MainActor
final class ReviewSprintModel: ObservableObject {
    enum Phase: Equatable {
        case running
        case finished(ReviewResults.Ending)
    }

    /// The keys the running screen answers to. Bare number keys are fine here: it has no text fields.
    enum Key: Equatable {
        case grade(ReviewGrade)
        /// Flips the card; once it is turned over, grades it Good.
        case space
        case pause
        case escape
    }

    @Published private(set) var queue: ReviewQueue
    @Published private(set) var run: ReviewRun
    @Published private(set) var isFlipped = false
    @Published private(set) var phase: Phase = .running
    /// The clock, as of the last tick; the screen redraws from it.
    @Published private(set) var now: Date
    /// "End sprint" was pressed and is waiting for a yes.
    @Published var isConfirmingEnd = false

    /// What the sprint was started with, for "Same mix again".
    let setup: ReviewSetup
    /// How many decks the mix has, from the queue as built.
    let deckCount: Int
    /// The decks in the mix, in the order they first come up.
    let mixDeckIDs: [Deck.ID]
    /// Past sprints as they stood when this one began, for the results' chips: "Last sprint" is the one
    /// before this, not this one.
    let history: ReviewResults.History

    private var dueCards: Set<Card.ID>
    private let decks: () -> [Deck]
    private let playback: () -> [Deck.ID: PlaybackState]
    private let grader: (ReviewGrade, Card.ID, Deck, Date) -> Void
    private let clock: () -> Date
    /// Spoken by VoiceOver: the time left at 1 minute, 30 seconds and 0.
    var onAnnouncement: ((String) -> Void)?
    /// Called once when the sprint is over: with the run to keep in the history, or nil when nothing was
    /// graded.
    private let onFinished: ((RunRecord?) -> Void)?
    /// Called when the clock or the count changes in a way the notch should show: the start, a grade, a
    /// pause or a resume. (Not every second: the notch counts the seconds itself.)
    private let onClock: ((StudyClockInfo) -> Void)?

    init(
        queue: ReviewQueue,
        minutes: Int,
        setup: ReviewSetup,
        dueCards: Set<Card.ID>,
        decks: @escaping () -> [Deck],
        playback: @escaping () -> [Deck.ID: PlaybackState],
        grader: @escaping (ReviewGrade, Card.ID, Deck, Date) -> Void,
        clock: @escaping () -> Date = { Date() },
        history: ReviewResults.History = .empty,
        onFinished: ((RunRecord?) -> Void)? = nil,
        onClock: ((StudyClockInfo) -> Void)? = nil
    ) {
        let start = clock()
        self.queue = queue
        self.run = ReviewRun(startedAt: start, minutes: minutes)
        self.now = start
        self.setup = setup
        var ids: [Deck.ID] = []
        for entry in queue.entries where !ids.contains(entry.deckID) { ids.append(entry.deckID) }
        self.mixDeckIDs = ids
        self.deckCount = ids.count
        self.history = history
        self.onFinished = onFinished
        self.onClock = onClock
        self.dueCards = dueCards
        self.decks = decks
        self.playback = playback
        self.grader = grader
        self.clock = clock
        skipMissingCards()
        reportClock()
    }

    /// Starts a sprint from the setup sheet's choices, on the decks as they are now.
    static func start(
        setup: ReviewSetup,
        decks: @escaping () -> [Deck],
        playback: @escaping () -> [Deck.ID: PlaybackState],
        grader: @escaping (ReviewGrade, Card.ID, Deck, Date) -> Void,
        clock: @escaping () -> Date = { Date() },
        history: ReviewResults.History = .empty,
        onFinished: ((RunRecord?) -> Void)? = nil,
        onClock: ((StudyClockInfo) -> Void)? = nil
    ) -> ReviewSprintModel {
        let start = clock()
        let library = decks()
        let states = playback()
        var generator = SystemRandomNumberGenerator()
        let queue = ReviewQueue.build(
            deckIDs: setup.ticked, in: library, playback: states, options: setup.options, now: start, using: &generator
        )
        var due = Set<Card.ID>()
        for deck in library where setup.ticked.contains(deck.id) {
            for card in deck.cards {
                if let review = states[deck.id]?.review(for: card.id), review.due <= start { due.insert(card.id) }
            }
        }
        return ReviewSprintModel(
            queue: queue, minutes: setup.minutes, setup: setup, dueCards: due,
            decks: decks, playback: playback, grader: grader, clock: clock, history: history,
            onFinished: onFinished, onClock: onClock
        )
    }

    /// The one-minute round of the cards that came up again.
    static func followUp(
        from results: ReviewResults,
        setup: ReviewSetup,
        decks: @escaping () -> [Deck],
        playback: @escaping () -> [Deck.ID: PlaybackState],
        grader: @escaping (ReviewGrade, Card.ID, Deck, Date) -> Void,
        clock: @escaping () -> Date = { Date() },
        history: ReviewResults.History = .empty,
        onFinished: ((RunRecord?) -> Void)? = nil,
        onClock: ((StudyClockInfo) -> Void)? = nil
    ) -> ReviewSprintModel {
        let queue = results.followUpQueue()
        var round = setup
        round.minutes = ReviewResults.followUpMinutes
        return ReviewSprintModel(
            queue: queue, minutes: ReviewResults.followUpMinutes, setup: round,
            dueCards: Set(queue.entries.map(\.cardID)), decks: decks, playback: playback, grader: grader, clock: clock,
            history: history, onFinished: onFinished, onClock: onClock
        )
    }

    // MARK: What is showing

    var current: (card: Card, deck: Deck)? {
        guard let entry = queue.current else { return nil }
        let library = decks()
        guard let deck = library.first(where: { $0.id == entry.deckID }),
              let card = deck.cards.first(where: { $0.id == entry.cardID }) else { return nil }
        return (card, deck)
    }

    var reviewed: Int { run.reviewed }
    var remaining: TimeInterval { run.remaining(at: now) }
    var isTimeUp: Bool { phase == .running && run.isTimeUp(at: now) }
    var isPaused: Bool { run.isPaused }
    var isRunning: Bool { phase == .running }
    /// Cards that were due and still have to come up, including ones graded Again.
    var dueLeft: Int { queue.entries.filter { dueCards.contains($0.cardID) }.count }
    /// The deck's name goes on the card when more than one deck is in the mix.
    var showsDeckName: Bool { deckCount > 1 }

    /// A card has to be turned over to be graded, and not while paused.
    var canGrade: Bool { isRunning && isFlipped && !isPaused && current != nil }

    /// "4 decks · Review sprint", or the deck's name for one.
    var title: String {
        if deckCount == 1, let name = current?.deck.name ?? decks().first(where: { $0.id == queue.entries.first?.deckID })?.name {
            return "\(name) · Review sprint"
        }
        return "\(deckCount) \(deckCount == 1 ? "deck" : "decks") · Review sprint"
    }

    /// What each grade would set for the card on screen.
    var intervals: GradeIntervals {
        guard let current else { return .forNewCard }
        return ReviewScheduler.intervals(from: playback()[current.deck.id]?.review(for: current.card.id))
    }

    /// Where the fish is on the time track, 0...1. With Reduce Motion it only takes whole steps.
    func trackProgress(reduceMotion: Bool) -> Double {
        Self.trackProgress(run: run, at: now, reduceMotion: reduceMotion)
    }

    static func trackProgress(run: ReviewRun, at now: Date, reduceMotion: Bool) -> Double {
        let elapsed = run.elapsed(at: now)
        guard reduceMotion else { return run.progress(at: now) }
        let stepped = (elapsed / FishSwim.reducedMotionStep).rounded(.down) * FishSwim.reducedMotionStep
        return min(max(stepped / run.duration, 0), 1)
    }

    // MARK: Actions

    func flip() {
        guard isRunning, !isPaused, current != nil else { return }
        isFlipped.toggle()
    }

    func grade(_ grade: ReviewGrade) {
        guard canGrade, let shown = current else { return }
        let date = clock()
        now = date
        grader(grade, shown.card.id, shown.deck, date)
        run.record(grade, cardID: shown.card.id, deckID: shown.deck.id, at: date)
        queue.grade(grade)
        if grade == .again { dueCards.insert(shown.card.id) }
        isFlipped = false
        if run.isEnded {
            finish(.timeUp)
            return
        }
        skipMissingCards()
        reportClock()
    }

    func togglePause() {
        guard isRunning else { return }
        let date = clock()
        now = date
        if run.isPaused { run.resume(at: date) } else if !run.isTimeUp(at: date) { run.pause(at: date) }
        reportClock()
    }

    /// The clock as the notch draws it. The end is worked out from what is left, so a pause that
    /// shifted it is accounted for.
    var clockInfo: StudyClockInfo {
        StudyClockInfo(
            kind: .sprint, startedAt: run.startedAt, endsAt: now.addingTimeInterval(run.remaining(at: now)),
            minutes: run.minutes, reviewed: run.reviewed, pausedAt: run.isPaused ? now : nil
        )
    }

    private func reportClock() {
        onClock?(clockInfo)
    }

    /// FishBrain is quitting: the sprint ends as if End sprint had been pressed, and is saved.
    func endForQuit() {
        guard isRunning else { return }
        isConfirmingEnd = false
        finish(.ended)
    }

    func confirmEnd() {
        guard isRunning else { return }
        finish(.ended)
    }

    /// Esc, Space, P and 1 to 4. Returns whether the key did something.
    @discardableResult
    func handle(_ key: Key) -> Bool {
        guard isRunning else { return false }
        switch key {
        case .grade(let grade):
            guard canGrade else { return false }
            self.grade(grade)
        case .space:
            guard !isPaused, current != nil else { return false }
            if isFlipped { grade(.good) } else { flip() }
        case .pause:
            togglePause()
        case .escape:
            isConfirmingEnd = true
        }
        return true
    }

    /// Called about twice a second while the screen is up.
    func tick() {
        guard isRunning else { return }
        let before = run.remaining(at: now)
        now = clock()
        if let text = Self.announcement(from: before, to: run.remaining(at: now)) { onAnnouncement?(text) }
        skipMissingCards()
    }

    /// The decks changed (a card was deleted): look at the card on screen again.
    func decksDidChange() { skipMissingCards() }

    /// "1 minute left", "30 seconds left", "Time's up" when the clock crosses them.
    static func announcement(from before: TimeInterval, to after: TimeInterval) -> String? {
        if before > 0, after <= 0 { return "Time's up" }
        if before > 30, after <= 30 { return "30 seconds left" }
        if before > 60, after <= 60 { return "1 minute left" }
        return nil
    }

    func results(study: StudySummary?) -> ReviewResults {
        let ending: ReviewResults.Ending
        if case .finished(let value) = phase { ending = value } else { ending = .ended }
        return ReviewResults(
            run: run, ending: ending, decks: decks(), study: study, history: history, mixDeckCount: deckCount
        )
    }

    // MARK: Private

    private func finish(_ ending: ReviewResults.Ending) {
        if !run.isEnded { run.end(at: clock()) }
        phase = .finished(ending)
        isConfirmingEnd = false
        isFlipped = false
        // A sprint with nothing graded says nothing about pace, so it isn't kept.
        onFinished?(run.reviewed > 0 ? RunRecord(run: run, deckIDs: mixDeckIDs) : nil)
    }

    /// A card deleted since the sprint began has nothing to show: it is dropped from the queue. The
    /// queue itself never changes otherwise, whatever happens to the decks.
    private func skipMissingCards() {
        guard isRunning else { return }
        while queue.current != nil, current == nil {
            queue.dropCurrent()
            isFlipped = false
        }
        if queue.isEmpty { finish(.queueFinished) }
    }
}

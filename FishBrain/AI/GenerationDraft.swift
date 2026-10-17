import Foundation

/// A card in the draft: what the model wrote, as the person has edited it, and whether it will be saved.
struct DraftCard: Identifiable, Equatable, Sendable {
    var id = UUID()
    var front: String
    var back: String
    /// The 1-based page of the PDF it came from, when known.
    var sourcePage: Int?
    /// Ticked cards are saved. All are ticked to begin with.
    var isSelected = true
    /// Changed by hand. A refine keeps these as they are unless it is asked to change them.
    var isEditedByPerson = false
    /// Came from a refine or "add more", not from the first run.
    var isAdded = false

    var refineCard: RefineCard {
        RefineCard(front: front, back: back, sourcePage: sourcePage, editedByPerson: isEditedByPerson)
    }
}

/// Something the draft can be doing at a time.
enum DraftOperation: Equatable, Sendable {
    /// The first run: the name, then the cards.
    case generate
    /// More cards, after a run that fell short or was stopped.
    case addMore(Int)
    /// "Refine all cards".
    case refine(String)
    /// ↻ on one card.
    case rewrite(DraftCard.ID)

    /// Writes new cards into the list one by one (as opposed to replacing what is there when it is done).
    var streamsCards: Bool {
        switch self {
        case .generate, .addMore: true
        case .refine, .rewrite: false
        }
    }
}

/// What can be done about a failure, offered next to its message.
enum DraftFix: Hashable, Sendable {
    case openSettings
    case tryAgain
    case addMore(Int)
    case startOver
}

/// The one inline banner: what went wrong, and what to do about it.
struct DraftProblem: Equatable, Sendable {
    var error: GenerationError
    var operation: DraftOperation
    var fixes: [DraftFix]

    var message: String { error.message }
}

/// How many of the cards are ticked: for the checkbox in the header.
enum DraftSelection: Equatable, Sendable {
    case none, some, all
}

/// Puts a model's whole new list of cards on top of the cards there are, keeping what didn't change.
enum DraftMerge {
    struct Result: Equatable {
        var cards: [DraftCard]
        /// Cards whose text the model changed.
        var changed: Set<DraftCard.ID>
        /// Cards that are new.
        var added: Set<DraftCard.ID>
    }

    private static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// For each card of the reply: the same card as before (nothing changes, and neither does its ticked or
    /// edited state), or the card with the same front but another back (changed: it keeps its place in the
    /// selection), or a new card (marked added, ticked). Cards the reply leaves out are gone.
    static func apply(reply: [GeneratedCard], to old: [DraftCard]) -> Result {
        var available = Array(old.indices)
        var matches = [Int?](repeating: nil, count: reply.count)
        // Exact matches first, so a changed card never takes the place of one that is unchanged.
        for (index, card) in reply.enumerated() {
            if let position = available.firstIndex(where: {
                key(old[$0].front) == key(card.front) && key(old[$0].back) == key(card.back)
            }) {
                matches[index] = available.remove(at: position)
            }
        }
        for (index, card) in reply.enumerated() where matches[index] == nil {
            if let position = available.firstIndex(where: { key(old[$0].front) == key(card.front) }) {
                matches[index] = available.remove(at: position)
            }
        }

        var cards: [DraftCard] = []
        var changed: Set<DraftCard.ID> = []
        var added: Set<DraftCard.ID> = []
        for (index, card) in reply.enumerated() {
            if let match = matches[index] {
                var kept = old[match]
                let same = key(kept.front) == key(card.front) && key(kept.back) == key(card.back)
                if !same {
                    kept.front = card.front
                    kept.back = card.back
                    kept.isEditedByPerson = false
                    changed.insert(kept.id)
                }
                kept.sourcePage = card.sourcePage ?? kept.sourcePage
                cards.append(kept)
            } else {
                let new = DraftCard(front: card.front, back: card.back, sourcePage: card.sourcePage, isAdded: true)
                added.insert(new.id)
                cards.append(new)
            }
        }
        return Result(cards: cards, changed: changed, added: added)
    }
}

/// The cards being made, from the first one arriving to being saved or thrown away. It lives in the app (not in
/// a screen), so leaving the screen keeps the draft as the sidebar's "Draft".
///
///     generating ──► review ──► saved   (the draft is gone, the cards are a deck)
///                       └─────► discarded
///
/// While it is generating, finished cards can already be edited. In review, the whole list can be refined, one
/// card can be rewritten, and more cards can be asked for.
@MainActor
final class GenerationDraft: ObservableObject {
    enum Phase: Equatable { case generating, review }

    static let skeletonRows = 4
    static let defaultName = DeckStore.defaultDeckName

    @Published private(set) var phase: Phase = .generating
    @Published private(set) var cards: [DraftCard] = []
    /// The deck's name: the model's suggestion until the person writes their own.
    @Published private(set) var name = ""
    @Published private(set) var isNameSuggested = false
    @Published private(set) var color: DeckColor = .accent
    @Published private(set) var activeOperation: DraftOperation?
    @Published private(set) var problem: DraftProblem?
    /// Cards a refine or rewrite just changed, for a brief highlight.
    @Published private(set) var changedIDs: Set<DraftCard.ID> = []
    /// The first thing (the name, or a card) has come back, so the material has been read.
    @Published private(set) var hasReceivedAnything = false
    /// The run was stopped by the person.
    @Published private(set) var wasStopped = false
    @Published private(set) var inputTokens = 0
    @Published private(set) var outputTokens = 0
    @Published private(set) var runs = 0
    /// A card the screen should scroll to and put the cursor in.
    @Published var focusRequest: DraftCard.ID?

    let plan: GenerationPlan
    let snapshot: ComposerSnapshot
    /// Called when the draft is over (saved or thrown away).
    var onClose: (() -> Void)?

    /// Cards from the model that count toward what was asked for (first run and "add more").
    private(set) var generatedCount = 0
    private var nameEditedByPerson = false
    private var task: Task<Void, Never>?

    init(plan: GenerationPlan, snapshot: ComposerSnapshot) {
        self.plan = plan
        self.snapshot = snapshot
        // Cards for a deck that exists: its name and color are not up for suggestion or change.
        if let target = plan.targetDeck {
            name = target.name
            color = target.color
        }
    }

    // MARK: Reading

    /// The deck the cards are being added to, when there is one: its name and color stay as they are.
    var targetDeck: TargetDeck? { plan.targetDeck }
    var isNameFixed: Bool { plan.targetDeck != nil }

    var requestedCount: Int { plan.request.cardCount }
    var modelName: String { plan.provider.model.displayName }
    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultName : name }
    var isBusy: Bool { activeOperation != nil }
    var selectedCount: Int { cards.filter(\.isSelected).count }

    var selection: DraftSelection {
        let selected = selectedCount
        return selected == 0 ? .none : (selected == cards.count ? .all : .some)
    }

    /// "19 of 20 selected"
    var selectedText: String { "\(selectedCount) of \(cards.count) selected" }

    /// Whether the cards can be saved now: not while cards are still arriving or being changed.
    var canSave: Bool { activeOperation == nil && selectedCount > 0 }

    /// Something that would be lost: cards, or a run in progress.
    var hasUnsavedWork: Bool { !cards.isEmpty || activeOperation != nil }

    /// What the sidebar row says: "9/20" while cards are arriving, "Draft" after.
    var badge: String { phase == .generating ? "\(generatedCount)/\(requestedCount)" : "Draft" }

    /// The grey rows that wait for the cards still to come.
    var skeletonCount: Int {
        guard phase == .generating else { return 0 }
        return min(max(requestedCount - generatedCount, 0), Self.skeletonRows)
    }

    /// 0 to 1 for the bar.
    var progress: Double {
        requestedCount > 0 ? min(Double(generatedCount) / Double(requestedCount), 1) : 0
    }

    /// "24 pages", "your material", or nil when there is none to read.
    var sourceSummary: String? {
        let request = plan.request
        guard !request.sources.isEmpty else { return nil }
        let pages = request.totalPDFPages
        return pages > 0 ? "\(pages) \(pages == 1 ? "page" : "pages")" : "your material"
    }

    /// "✓ Read 24 pages · Writing cards 9 of 20"
    var progressText: String {
        let writing = "Writing cards \(generatedCount) of \(requestedCount)"
        guard let summary = sourceSummary else { return writing }
        return hasReceivedAnything ? "✓ Read \(summary) · \(writing)" : "Reading \(summary)…"
    }

    /// "Got 17 of 20" or "Stopped at 9 of 20", and how many to ask for to make up the difference. Nil when the
    /// run gave what was asked for, or something else is on the screen.
    var shortfall: (text: String, missing: Int)? {
        guard phase == .review, activeOperation == nil, problem == nil, generatedCount < requestedCount else { return nil }
        let missing = requestedCount - generatedCount
        // The same words as `CountCheck.shortfallText` ("Got 17 of 20"), or what the person stopped at.
        return ((wasStopped ? "Stopped at" : "Got") + " \(generatedCount) of \(requestedCount)", missing)
    }

    /// "This run cost about $0.21 (estimate · prices updated 8 Oct 2026)": from the tokens the provider
    /// reported, adding up every run of this draft. Nil until a run is over, and when the price isn't known.
    var costText: String? {
        guard runs > 0, activeOperation == nil, let price = AIPricing.price(for: plan.provider.model.id) else { return nil }
        let cost = price.cost(inputTokens: inputTokens, outputTokens: outputTokens)
        return (runs > 1 ? "These runs cost " : "This run cost ") + AIPricing.costLine(cost)
    }

    // MARK: Starting and stopping

    func start() {
        guard activeOperation == nil, phase == .generating, generatedCount == 0 else { return }
        begin(.generate, request: plan.request, limit: requestedCount)
    }

    /// Stops the request and keeps the cards that are finished.
    func stop() {
        task?.cancel()
    }

    /// Ends whatever is running, for a draft that is going away.
    func cancelAll() {
        task?.cancel()
        task = nil
    }

    private func begin(_ operation: DraftOperation, request: GenerationRequest, limit: Int) {
        guard activeOperation == nil else { return }
        guard let generator = plan.makeGenerator() else {
            fail(.invalidKey, operation)
            return
        }
        activeOperation = operation
        problem = nil
        wasStopped = false
        if operation.streamsCards { phase = .generating }
        task = Task { [weak self] in
            await self?.consume(generator.generate(request), operation: operation, limit: limit)
        }
    }

    private func consume(_ stream: AsyncThrowingStream<GenerationEvent, Error>, operation: DraftOperation, limit: Int) async {
        var received: [GeneratedCard] = []
        var suggestedName: String?
        var accepted = 0
        var failure: GenerationError?
        do {
            for try await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .deckName(let value):
                    hasReceivedAnything = true
                    suggestedName = value
                    if operation == .generate { suggest(value) }
                case .card(let card):
                    hasReceivedAnything = true
                    received.append(card)
                    if operation.streamsCards, accepted < limit, accept(card, isAdded: operation != .generate) { accepted += 1 }
                case .finished(let usage):
                    runs += 1
                    inputTokens += usage?.inputTokens ?? 0
                    outputTokens += usage?.outputTokens ?? 0
                }
            }
        } catch is CancellationError {
            // Stopped.
        } catch let error as GenerationError {
            failure = error
        } catch {
            failure = .network
        }
        finish(operation, received: received, suggestedName: suggestedName, failure: Task.isCancelled ? nil : failure, stopped: Task.isCancelled)
    }

    private func finish(_ operation: DraftOperation, received: [GeneratedCard], suggestedName: String?, failure: GenerationError?, stopped: Bool) {
        task = nil
        activeOperation = nil
        phase = .review
        if stopped {
            wasStopped = operation.streamsCards
            return
        }
        if let failure {
            fail(failure, operation)
            return
        }
        switch operation {
        case .generate, .addMore:
            break
        case .refine:
            guard !received.isEmpty else { fail(.badResponse, operation); return }
            let result = DraftMerge.apply(reply: received, to: cards)
            cards = result.cards
            changedIDs = result.changed
            if let suggestedName { suggest(suggestedName) }
        case .rewrite(let id):
            guard let card = received.first, let index = cards.firstIndex(where: { $0.id == id }) else {
                fail(.badResponse, operation)
                return
            }
            cards[index].front = card.front
            cards[index].back = card.back
            cards[index].sourcePage = card.sourcePage ?? cards[index].sourcePage
            cards[index].isEditedByPerson = false
            changedIDs = [id]
        }
    }

    /// Adds a card the model wrote. A card with the same front as one already there is left out when asked for
    /// more cards, so the list doesn't repeat itself.
    @discardableResult
    private func accept(_ card: GeneratedCard, isAdded: Bool) -> Bool {
        let front = card.front.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isAdded, cards.contains(where: { $0.front.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == front }) {
            return false
        }
        cards.append(DraftCard(front: card.front, back: card.back, sourcePage: card.sourcePage, isAdded: isAdded))
        generatedCount += 1
        return true
    }

    private func suggest(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !nameEditedByPerson, !isNameFixed else { return }
        name = trimmed
        isNameSuggested = true
    }

    // MARK: Failures

    private func fail(_ error: GenerationError, _ operation: DraftOperation) {
        activeOperation = nil
        phase = .review
        problem = DraftProblem(error: error, operation: operation, fixes: fixes(for: error, operation: operation))
    }

    /// What is offered next to each message: Open Settings, Try again, Add more cards, Start over.
    func fixes(for error: GenerationError, operation: DraftOperation) -> [DraftFix] {
        switch error {
        case .invalidKey, .modelForbidden, .modelUnavailable, .modelCantMakeCards, .outOfCredit, .onDeviceUnavailable:
            return [.openSettings, .tryAgain]
        case .rateLimited, .overloaded, .network, .badResponse:
            return [.tryAgain]
        case .truncated:
            let missing = max(requestedCount - generatedCount, 0)
            return operation.streamsCards && missing > 0 ? [.addMore(missing)] : [.tryAgain]
        case .refused, .tooLarge, .imagesNotSupported, .languageNotSupported, .noReadableText:
            return [.startOver]
        }
    }

    func dismissProblem() { problem = nil }

    /// Does again what failed. A first run that gave nothing starts over; one that gave some cards asks for the
    /// rest.
    func retry() {
        guard let failed = problem?.operation else { return }
        problem = nil
        switch failed {
        case .generate:
            if generatedCount == 0 {
                phase = .generating
                begin(.generate, request: plan.request, limit: requestedCount)
            } else {
                addMore(max(requestedCount - generatedCount, 1))
            }
        case .addMore(let count): addMore(count)
        case .refine(let instruction): refine(instruction)
        case .rewrite(let id): rewrite(id)
        }
    }

    // MARK: Asking for more

    /// Asks for `count` more cards, told which fronts to avoid.
    func addMore(_ count: Int) {
        guard count > 0, activeOperation == nil else { return }
        var request = plan.request
        request.cardCount = count
        request.existingFronts = cards.map(\.front)
        begin(.addMore(count), request: request, limit: count)
    }

    /// "Refine all cards": sends the cards as they are with what the person asks, and the reply replaces the list.
    func refine(_ instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !cards.isEmpty, activeOperation == nil, phase == .review else { return }
        var request = plan.request
        request.cardCount = cards.count
        request.existingFronts = []
        request.task = .refine(instruction: trimmed, deckName: displayName, cards: cards.map(\.refineCard))
        begin(.refine(trimmed), request: request, limit: .max)
    }

    /// ↻: one new card for the same source page, told the deck's other fronts.
    func rewrite(_ id: DraftCard.ID) {
        guard let card = cards.first(where: { $0.id == id }), activeOperation == nil, phase == .review else { return }
        var request = plan.request
        request.cardCount = 1
        request.existingFronts = cards.filter { $0.id != id }.map(\.front)
        request.task = .replace(card: card.refineCard, deckName: displayName)
        begin(.rewrite(id), request: request, limit: 1)
    }

    /// The brief highlight is over.
    func clearChanged() { changedIDs = [] }

    // MARK: Editing

    func rename(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isNameFixed else { return }
        name = trimmed
        nameEditedByPerson = true
        isNameSuggested = false
    }

    func setColor(_ color: DeckColor) {
        guard !isNameFixed else { return }
        self.color = color
    }

    func setFront(_ id: DraftCard.ID, _ text: String) { edit(id, \.front, text) }
    func setBack(_ id: DraftCard.ID, _ text: String) { edit(id, \.back, text) }

    /// A change by hand: the card is then kept as it is by a refine unless that is asked for.
    private func edit(_ id: DraftCard.ID, _ keyPath: WritableKeyPath<DraftCard, String>, _ text: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }), cards[index][keyPath: keyPath] != text else { return }
        cards[index][keyPath: keyPath] = text
        cards[index].isEditedByPerson = true
    }

    func toggle(_ id: DraftCard.ID) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].isSelected.toggle()
    }

    /// The header's checkbox: ticks everything, or, when everything is ticked, clears it.
    func toggleAll() {
        let tick = selection != .all
        for index in cards.indices { cards[index].isSelected = tick }
    }

    /// "＋ Add a card yourself": an empty card at the end, ready to type in.
    func addCardYourself() {
        let card = DraftCard(front: "", back: "", isEditedByPerson: true)
        cards.append(card)
        focusRequest = card.id
    }

    // MARK: Saving

    /// The ticked cards, in order.
    var selectedCards: [DraftCard] { cards.filter(\.isSelected) }

    /// Makes a deck of the ticked cards and ends the draft. Returns the deck so it can be selected.
    @discardableResult
    func saveAsNewDeck(in store: DeckStore) -> Deck.ID? {
        guard canSave else { return nil }
        let deck = store.add(Deck(name: displayName, color: color, cards: selectedCards.map { Card(front: $0.front, back: $0.back) }))
        close()
        return deck.id
    }

    /// Adds the ticked cards to the end of an existing deck and ends the draft.
    @discardableResult
    func save(to deckID: Deck.ID, in store: DeckStore) -> Deck.ID? {
        guard canSave, store.decks.contains(where: { $0.id == deckID }) else { return nil }
        store.addCards(selectedCards.map { ParsedCard(front: $0.front, back: $0.back) }, to: deckID)
        close()
        return deckID
    }

    /// Adds the ticked cards to the deck they were asked for (`targetDeck`).
    @discardableResult
    func saveToTargetDeck(in store: DeckStore) -> Deck.ID? {
        guard let target = plan.targetDeck else { return nil }
        return save(to: target.id, in: store)
    }

    private func close() {
        cancelAll()
        onClose?()
    }
}

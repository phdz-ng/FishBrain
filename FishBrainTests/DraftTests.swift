import XCTest

/// Generating and review (FLAS-50): the draft's state machine, editing and selecting, refine and rewrite,
/// saving, the cost line, and the prompts for refine and rewrite. Nothing here goes online.

// MARK: - Fakes

/// Lets a script wait until the test says go.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func open() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        toResume.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// A provider that says what it is told to, one script per call, and remembers what it was asked.
final class ScriptedGenerator: CardGenerator, @unchecked Sendable {
    enum Step {
        case event(GenerationEvent)
        case fail(Error)
        /// Waits for the gate (or for the run to be stopped).
        case wait(Gate)
        /// Never ends by itself.
        case hang
    }

    private let lock = NSLock()
    private var scripts: [[Step]]
    private var _requests: [GenerationRequest] = []

    init(_ scripts: [[Step]]) { self.scripts = scripts }

    var requests: [GenerationRequest] { lock.withLock { _requests } }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let script: [Step] = lock.withLock {
            _requests.append(request)
            return scripts.isEmpty ? [.fail(GenerationError.badResponse)] : scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for step in script {
                    if Task.isCancelled { break }
                    switch step {
                    case .event(let event): continuation.yield(event)
                    case .fail(let error):
                        continuation.finish(throwing: error)
                        return
                    case .wait(let gate): await gate.wait()
                    case .hang:
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum DraftFixtures {
    static let usage = GenerationUsage(inputTokens: 1000, outputTokens: 500)

    static func cards(_ range: ClosedRange<Int>) -> [GeneratedCard] { range.map { card($0) } }

    static func card(_ n: Int, page: Int? = nil) -> GeneratedCard {
        GeneratedCard(front: "Front \(n)", back: "Back \(n)", sourcePage: page ?? n)
    }

    /// A script that gives a name, `count` cards and the tokens used.
    static func run(name: String = "Cellular Respiration", cards: ClosedRange<Int> = 1...3, usage: GenerationUsage? = usage) -> [ScriptedGenerator.Step] {
        [.event(.deckName(name))] + cards.map { .event(.card(card($0))) } + [.event(.finished(usage))]
    }

    static let opus = AIModel(
        provider: .anthropic, id: "claude-opus-5-5", displayName: "Claude Opus 5.5", created: nil, supportsImages: true,
        supportsStructuredOutput: true, supportsEffort: true, maxInputTokens: 1_000_000, maxOutputTokens: 128_000
    )

    static func snapshot() -> ComposerSnapshot {
        ComposerSnapshot(items: [], focus: "", style: .questionAnswer, languageName: nil, destination: .newDeck, countOverride: nil, customCountChosen: false)
    }

    static func plan(
        _ generator: CardGenerator?, count: Int = 20, pdfPages: Int = 0, destination: ComposerDestination = .newDeck,
        model: AIModel = opus, focus: String = "the Krebs cycle"
    ) -> GenerationPlan {
        var sources: [GenerationSource] = []
        if pdfPages > 0 { sources.append(.pdf(PDFSource(data: Data([1]), filename: "Cells.pdf", pageCount: pdfPages))) }
        let request = GenerationRequest(sources: sources, focus: focus, cardCount: count, modelID: model.id)
        return GenerationPlan(
            request: request, destination: destination, provider: ComposerProvider(provider: model.provider, model: model),
            makeGenerator: { generator }
        )
    }
}

/// Waits until something is true (cards arrive on their own time).
@MainActor
func eventually(_ message: String = "", timeout: TimeInterval = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return XCTFail("Timed out: \(message)", file: file, line: line) }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - The state machine

@MainActor
final class DraftStateTests: XCTestCase {
    private func make(_ scripts: [[ScriptedGenerator.Step]], count: Int = 20, pdfPages: Int = 0, model: AIModel = DraftFixtures.opus) -> (GenerationDraft, ScriptedGenerator) {
        let generator = ScriptedGenerator(scripts)
        let draft = GenerationDraft(plan: DraftFixtures.plan(generator, count: count, pdfPages: pdfPages, model: model), snapshot: DraftFixtures.snapshot())
        return (draft, generator)
    }

    private func finished(_ draft: GenerationDraft) async {
        await eventually("the run ends") { !draft.isBusy }
    }

    func testTheNameComesFirstThenTheCardsOneByOne() async {
        let gate = Gate()
        let (draft, _) = make([[.event(.deckName("Cellular Respiration")), .wait(gate), .event(.card(DraftFixtures.card(1))), .hang]], pdfPages: 24)
        draft.start()
        await eventually("the name") { draft.name == "Cellular Respiration" }
        XCTAssertTrue(draft.isNameSuggested)
        XCTAssertTrue(draft.cards.isEmpty, "the name is shown before any card")
        XCTAssertEqual(draft.phase, .generating)
        XCTAssertEqual(draft.progressText, "✓ Read 24 pages · Writing cards 0 of 20")
        XCTAssertEqual(draft.skeletonCount, 4, "waiting rows for the cards to come")

        gate.open()
        await eventually("a card") { draft.cards.count == 1 }
        XCTAssertEqual(draft.cards.first, DraftCard(id: draft.cards[0].id, front: "Front 1", back: "Back 1", sourcePage: 1))
        XCTAssertEqual(draft.badge, "1/20")
        XCTAssertEqual(draft.progress, 0.05, accuracy: 1e-9)
        draft.stop()
        await finished(draft)
    }

    func testBeforeAnythingArrivesTheMaterialIsBeingRead() {
        let (draft, _) = make([[.hang]], pdfPages: 24)
        XCTAssertEqual(draft.progressText, "Reading 24 pages…")
        let (noSources, _) = make([[.hang]])
        XCTAssertEqual(noSources.progressText, "Writing cards 0 of 20")
        XCTAssertEqual(noSources.sourceSummary, nil)
    }

    func testARunThatFinishesIsReadyToReview() async {
        let (draft, generator) = make([DraftFixtures.run(cards: 1...3)], count: 3)
        draft.start()
        await finished(draft)
        XCTAssertEqual(draft.phase, .review)
        XCTAssertEqual(draft.cards.map(\.front), ["Front 1", "Front 2", "Front 3"])
        XCTAssertEqual(draft.badge, "Draft")
        XCTAssertNil(draft.problem)
        XCTAssertNil(draft.shortfall)
        XCTAssertEqual(draft.skeletonCount, 0)
        XCTAssertEqual(draft.selectedCount, 3, "all ticked to begin with")
        XCTAssertEqual(generator.requests.count, 1)
        XCTAssertEqual(generator.requests.first?.task, .create)
    }

    func testCardsBeyondWhatWasAskedForAreLeftOut() async {
        let (draft, _) = make([DraftFixtures.run(cards: 1...5)], count: 3)
        draft.start()
        await finished(draft)
        XCTAssertEqual(draft.cards.map(\.front), ["Front 1", "Front 2", "Front 3"], "the first N")
        XCTAssertEqual(draft.generatedCount, 3)
    }

    func testStopKeepsTheFinishedCardsAndOffersTheRest() async {
        let (draft, _) = make([[.event(.deckName("Deck")), .event(.card(DraftFixtures.card(1))), .event(.card(DraftFixtures.card(2))), .hang]])
        draft.start()
        await eventually("two cards") { draft.cards.count == 2 }
        draft.stop()
        await finished(draft)
        XCTAssertEqual(draft.phase, .review)
        XCTAssertEqual(draft.cards.count, 2)
        XCTAssertTrue(draft.wasStopped)
        XCTAssertNil(draft.problem, "stopping isn't an error")
        XCTAssertEqual(draft.shortfall?.text, "Stopped at 2 of 20")
        XCTAssertEqual(draft.shortfall?.missing, 18)
        XCTAssertEqual(draft.badge, "Draft")
    }

    func testFinishedCardsCanBeEditedWhileOthersAreStillArriving() async {
        let gate = Gate()
        let (draft, _) = make([[.event(.card(DraftFixtures.card(1))), .wait(gate), .event(.card(DraftFixtures.card(2))), .event(.finished(DraftFixtures.usage))]], count: 2)
        draft.start()
        await eventually("the first card") { draft.cards.count == 1 }
        let id = draft.cards[0].id
        draft.setFront(id, "My own front")
        XCTAssertTrue(draft.cards[0].isEditedByPerson)
        XCTAssertEqual(draft.phase, .generating)
        XCTAssertFalse(draft.canSave, "not while cards are still arriving")
        gate.open()
        await finished(draft)
        XCTAssertEqual(draft.cards.map(\.front), ["My own front", "Front 2"], "the edit survived the next card")
        XCTAssertTrue(draft.canSave)
    }

    func testAShortRunSaysHowManyItGot() async {
        let (draft, _) = make([DraftFixtures.run(cards: 1...3)], count: 5)
        draft.start()
        await finished(draft)
        XCTAssertEqual(draft.shortfall?.text, "Got 3 of 5")
        XCTAssertEqual(draft.shortfall?.missing, 2)
    }

    // MARK: Failures

    func testAnErrorKeepsTheCardsAlreadyThereAndOffersToTryAgain() async {
        let (draft, generator) = make([
            [.event(.deckName("Deck")), .event(.card(DraftFixtures.card(1))), .fail(GenerationError.network)],
            DraftFixtures.run(cards: 2...3, usage: nil),
        ], count: 3)
        draft.start()
        await finished(draft)
        XCTAssertEqual(draft.problem?.error, .network)
        XCTAssertEqual(draft.problem?.fixes, [.tryAgain])
        XCTAssertEqual(draft.problem?.message, "No network connection")
        XCTAssertEqual(draft.cards.count, 1, "kept")
        XCTAssertEqual(draft.phase, .review)

        draft.retry()
        await finished(draft)
        XCTAssertNil(draft.problem)
        // With a card already there, trying again asks for the rest, and says what to avoid.
        let second = generator.requests[1]
        XCTAssertEqual(second.cardCount, 2)
        XCTAssertEqual(second.existingFronts, ["Front 1"])
        XCTAssertEqual(second.task, .create)
        XCTAssertEqual(draft.cards.map(\.front), ["Front 1", "Front 2", "Front 3"])
        XCTAssertEqual(draft.cards.map(\.isAdded), [false, true, true])
    }

    func testAFailureBeforeAnyCardStartsTheRunAgain() async {
        let (draft, generator) = make([[.fail(GenerationError.overloaded)], DraftFixtures.run(cards: 1...2)], count: 2)
        draft.start()
        await finished(draft)
        XCTAssertEqual(draft.problem?.error, .overloaded)
        XCTAssertTrue(draft.cards.isEmpty)
        draft.retry()
        await finished(draft)
        XCTAssertEqual(draft.cards.count, 2)
        XCTAssertEqual(generator.requests[1].cardCount, 2, "the whole run, not just the rest")
        XCTAssertEqual(generator.requests[1].existingFronts, [])
        XCTAssertEqual(draft.cards.map(\.isAdded), [false, false])
    }

    func testTruncatedKeepsTheCardsAndOffersToAddMore() async {
        let (draft, generator) = make([
            [.event(.deckName("Deck")), .event(.card(DraftFixtures.card(1))), .event(.card(DraftFixtures.card(2))), .event(.finished(DraftFixtures.usage)), .fail(GenerationError.truncated)],
            DraftFixtures.run(cards: 3...4, usage: nil),
        ], count: 4)
        draft.start()
        await finished(draft)
        XCTAssertEqual(draft.problem?.error, .truncated)
        XCTAssertEqual(draft.problem?.fixes, [.addMore(2)])
        XCTAssertEqual(draft.runs, 1, "the tokens of the cut-off answer are counted")
        draft.dismissProblem()
        draft.addMore(2)
        await finished(draft)
        XCTAssertEqual(draft.cards.count, 4)
        XCTAssertEqual(generator.requests[1].existingFronts, ["Front 1", "Front 2"])
        XCTAssertEqual(draft.cards.suffix(2).map(\.isAdded), [true, true])
        XCTAssertNil(draft.shortfall)
    }

    func testAddMoreSkipsACardThatRepeatsOne() async {
        let repeated = GeneratedCard(front: " front 1 ", back: "same again", sourcePage: 1)
        let (draft, _) = make([DraftFixtures.run(cards: 1...2), [.event(.card(repeated)), .event(.card(DraftFixtures.card(9))), .event(.finished(nil))]], count: 3)
        draft.start()
        await finished(draft)
        draft.addMore(1)
        await finished(draft)
        XCTAssertEqual(draft.cards.map(\.front), ["Front 1", "Front 2", "Front 9"], "the repeat is left out; the next card fills its place")
    }

    func testWhatToDoAboutEachError() {
        let (draft, _) = make([[.hang]])
        func fixes(_ error: GenerationError, _ operation: DraftOperation = .generate) -> [DraftFix] {
            draft.fixes(for: error, operation: operation)
        }
        for error in [GenerationError.invalidKey, .modelForbidden, .modelUnavailable, .modelCantMakeCards, .outOfCredit] {
            XCTAssertEqual(fixes(error), [.openSettings, .tryAgain], "\(error)")
        }
        for error in [GenerationError.rateLimited(retryAfter: 5), .overloaded, .network, .badResponse] {
            XCTAssertEqual(fixes(error), [.tryAgain], "\(error)")
        }
        for error in [GenerationError.refused, .tooLarge, .imagesNotSupported] {
            XCTAssertEqual(fixes(error), [.startOver], "\(error)")
        }
        XCTAssertEqual(fixes(.truncated), [.addMore(20)])
        XCTAssertEqual(fixes(.truncated, .refine("shorter")), [.tryAgain], "a cut-off refine is asked again")
    }

    func testAMissingKeyIsAnInvalidKeyProblemAndNothingIsSent() async {
        let draft = GenerationDraft(plan: DraftFixtures.plan(nil), snapshot: DraftFixtures.snapshot())
        draft.start()
        XCTAssertEqual(draft.problem?.error, .invalidKey)
        XCTAssertFalse(draft.isBusy)
        XCTAssertEqual(draft.phase, .review)
    }

    func testAPolicyRefusalOffersToStartOver() async {
        let (draft, _) = make([[.event(.finished(DraftFixtures.usage)), .fail(GenerationError.refused)]])
        draft.start()
        await finished(draft)
        XCTAssertEqual(draft.problem?.fixes, [.startOver])
        XCTAssertTrue(draft.cards.isEmpty)
    }

    // MARK: Selecting

    private func reviewed(_ count: Int = 5) async -> (GenerationDraft, ScriptedGenerator) {
        let (draft, generator) = make([DraftFixtures.run(cards: 1...count)], count: count)
        draft.start()
        await finished(draft)
        return (draft, generator)
    }

    func testSelectingCardsCountsThem() async {
        let (draft, _) = await reviewed(5)
        XCTAssertEqual(draft.selectedText, "5 of 5 selected")
        XCTAssertEqual(draft.selection, .all)
        draft.toggle(draft.cards[1].id)
        XCTAssertEqual(draft.selectedText, "4 of 5 selected")
        XCTAssertEqual(draft.selection, .some)
        draft.toggleAll()
        XCTAssertEqual(draft.selection, .all, "from some, the header ticks everything")
        draft.toggleAll()
        XCTAssertEqual(draft.selection, .none)
        XCTAssertEqual(draft.selectedCount, 0)
        XCTAssertFalse(draft.canSave)
        draft.toggle(draft.cards[0].id)
        XCTAssertTrue(draft.canSave)
    }

    func testAddingACardYourselfPutsTheCursorInIt() async {
        let (draft, _) = await reviewed(2)
        draft.addCardYourself()
        XCTAssertEqual(draft.cards.count, 3)
        XCTAssertEqual(draft.cards.last?.front, "")
        XCTAssertEqual(draft.cards.last?.isSelected, true)
        XCTAssertEqual(draft.cards.last?.isEditedByPerson, true)
        XCTAssertEqual(draft.focusRequest, draft.cards.last?.id)
        XCTAssertEqual(draft.selectedText, "3 of 3 selected")
    }

    func testEditingMarksACardAsEditedByHandOnlyWhenItChanges() async {
        let (draft, _) = await reviewed(2)
        let id = draft.cards[0].id
        draft.setBack(id, "Back 1")
        XCTAssertFalse(draft.cards[0].isEditedByPerson, "typing the same thing is no edit")
        draft.setBack(id, "Shorter")
        XCTAssertTrue(draft.cards[0].isEditedByPerson)
        XCTAssertFalse(draft.cards[1].isEditedByPerson)
        draft.setFront(UUID(), "nobody")
        XCTAssertEqual(draft.cards.count, 2, "an unknown card is ignored")
    }

    // MARK: Name and color

    func testTheNameIsASuggestionUntilThePersonWritesTheirOwn() async {
        let (draft, _) = await reviewed(2)
        XCTAssertEqual(draft.name, "Cellular Respiration")
        XCTAssertTrue(draft.isNameSuggested)
        draft.rename("  My Deck  ")
        XCTAssertEqual(draft.name, "My Deck")
        XCTAssertFalse(draft.isNameSuggested)
        draft.rename("   ")
        XCTAssertEqual(draft.name, "My Deck", "a blank name is ignored")
        draft.setColor(.purple)
        XCTAssertEqual(draft.color, .purple)
    }

    func testANameWithNothingSuggestedIsNewDeck() {
        let (draft, _) = make([[.hang]])
        XCTAssertEqual(draft.displayName, "New Deck")
    }

    // MARK: Saving

    private func makeStore(decks: [Deck] = []) -> DeckStore { PreviewData.store(decks: decks) }

    func testSavingMakesADeckOfExactlyTheTickedCardsInOrder() async throws {
        let (draft, _) = await reviewed(5)
        draft.toggle(draft.cards[1].id)
        draft.toggle(draft.cards[3].id)
        draft.setBack(draft.cards[4].id, "Edited back")
        draft.rename("Glycolysis")
        draft.setColor(.green)
        var closed = 0
        draft.onClose = { closed += 1 }
        let store = makeStore(decks: [Deck(name: "Existing")])

        let id = try XCTUnwrap(draft.saveAsNewDeck(in: store))
        XCTAssertEqual(store.decks.count, 2)
        let deck = try XCTUnwrap(store.decks.first { $0.id == id })
        XCTAssertEqual(deck.name, "Glycolysis")
        XCTAssertEqual(deck.color, .green)
        XCTAssertEqual(deck.cards.map(\.front), ["Front 1", "Front 3", "Front 5"])
        XCTAssertEqual(deck.cards.map(\.back), ["Back 1", "Back 3", "Edited back"])
        XCTAssertEqual(closed, 1, "the draft is over")
        XCTAssertEqual(store.decks.first?.cards.count, 0, "the other deck is untouched")
    }

    func testNothingIsSavedWhenNothingIsTickedOrCardsAreStillArriving() async {
        let (draft, _) = await reviewed(2)
        draft.toggleAll()
        let store = makeStore()
        XCTAssertNil(draft.saveAsNewDeck(in: store))
        XCTAssertTrue(store.decks.isEmpty)

        let (busy, _) = make([[.event(.card(DraftFixtures.card(1))), .hang]])
        busy.start()
        await eventually("a card") { busy.cards.count == 1 }
        XCTAssertNil(busy.saveAsNewDeck(in: store))
        busy.stop()
        await finished(busy)
    }

    func testSavingToAnExistingDeckAddsTheTickedCardsAtTheEnd() async throws {
        let (draft, _) = await reviewed(3)
        draft.toggle(draft.cards[0].id)
        let deck = Deck(name: "Bio", cards: [Card(front: "Old", back: "card")])
        let store = makeStore(decks: [deck])
        var closed = false
        draft.onClose = { closed = true }
        let id = draft.save(to: deck.id, in: store)
        XCTAssertEqual(id, deck.id)
        XCTAssertEqual(store.decks[0].cards.map(\.front), ["Old", "Front 2", "Front 3"])
        XCTAssertTrue(closed)
        XCTAssertEqual(store.decks.count, 1)
    }

    func testSavingToADeckThatIsGoneDoesNothing() async {
        let (draft, _) = await reviewed(2)
        let store = makeStore()
        XCTAssertNil(draft.save(to: UUID(), in: store))
        XCTAssertFalse(draft.cards.isEmpty, "the draft is still there")
    }

    func testSavedCardsAreNewCardsWithNoDraftState() async throws {
        let (draft, _) = await reviewed(2)
        let store = makeStore()
        _ = draft.saveAsNewDeck(in: store)
        let cards = try XCTUnwrap(store.decks.first?.cards)
        XCTAssertEqual(Set(cards.map(\.id)).intersection(Set(draft.cards.map(\.id))), [], "ids of their own")
        XCTAssertTrue(cards.allSatisfy { $0.frontImage == nil && $0.backImage == nil })
    }

    // MARK: Cost

    func testTheCostComesFromTheTokensReportedAndSaysItIsAnEstimate() async throws {
        let (draft, _) = make([DraftFixtures.run()], count: 3)
        XCTAssertNil(draft.costText)
        draft.start()
        await finished(draft)
        // 1000 in and 500 out on Opus 5.5 ($4 and $20 per million): $0.014.
        let text = try XCTUnwrap(draft.costText)
        XCTAssertEqual(text, "This run cost about $0.01 \(AIPricing.estimateNote())")
        XCTAssertTrue(text.contains("estimate"))
        XCTAssertTrue(text.contains("prices updated"))
        XCTAssertTrue(text.contains(AIPricing.updatedText()))
    }

    func testNoCostWhenThePriceIsNotKnown() async {
        let mystery = AIModel(provider: .anthropic, id: "claude-mystery-9", displayName: "Mystery", created: nil)
        let (draft, _) = make([DraftFixtures.run()], count: 3, model: mystery)
        draft.start()
        await finished(draft)
        XCTAssertNil(draft.costText)
    }

    func testEveryRunAddsToTheTotal() async throws {
        let (draft, _) = make([
            DraftFixtures.run(cards: 1...2),
            [.event(.deckName("Cellular Respiration")), .event(.card(DraftFixtures.card(1))), .event(.card(DraftFixtures.card(2))), .event(.finished(GenerationUsage(inputTokens: 3000, outputTokens: 700)))],
        ], count: 2)
        draft.start()
        await finished(draft)
        let first = try XCTUnwrap(draft.costText)
        XCTAssertTrue(first.hasPrefix("This run cost"))
        draft.refine("make the answers shorter")
        await finished(draft)
        XCTAssertEqual(draft.runs, 2)
        XCTAssertEqual(draft.inputTokens, 4000)
        XCTAssertEqual(draft.outputTokens, 1200)
        XCTAssertTrue(try XCTUnwrap(draft.costText).hasPrefix("These runs cost"))
    }

    func testTheCostIsNotShownWhileARunIsGoing() async {
        let (draft, _) = make([[.event(.card(DraftFixtures.card(1))), .event(.finished(DraftFixtures.usage)), .hang]])
        draft.start()
        await eventually("a card") { draft.runs == 1 }
        XCTAssertNil(draft.costText)
        draft.stop()
        await finished(draft)
    }
}

// MARK: - Refine and rewrite

@MainActor
final class DraftRefineTests: XCTestCase {
    private func reviewed(
        _ followUps: [[ScriptedGenerator.Step]], count: Int = 3, pdfPages: Int = 24
    ) async -> (GenerationDraft, ScriptedGenerator) {
        let generator = ScriptedGenerator([DraftFixtures.run(cards: 1...count)] + followUps)
        let draft = GenerationDraft(plan: DraftFixtures.plan(generator, count: count, pdfPages: pdfPages), snapshot: DraftFixtures.snapshot())
        draft.start()
        await eventually("the first run") { !draft.isBusy }
        return (draft, generator)
    }

    private func reply(name: String = "Cellular Respiration", _ cards: [GeneratedCard], usage: GenerationUsage? = DraftFixtures.usage) -> [ScriptedGenerator.Step] {
        [.event(.deckName(name))] + cards.map { .event(.card($0)) } + [.event(.finished(usage))]
    }

    func testRefineSendsTheCardsAndWhatIsAsked() async throws {
        let (draft, generator) = await reviewed([reply(DraftFixtures.cards(1...3))])
        draft.setBack(draft.cards[1].id, "My answer")
        draft.refine("  make the answers shorter  ")
        await eventually("refined") { !draft.isBusy }
        let request = try XCTUnwrap(generator.requests.last)
        guard case .refine(let instruction, let deckName, let cards) = request.task else { return XCTFail("a refine") }
        XCTAssertEqual(instruction, "make the answers shorter")
        XCTAssertEqual(deckName, "Cellular Respiration")
        XCTAssertEqual(cards.map(\.front), ["Front 1", "Front 2", "Front 3"])
        XCTAssertEqual(cards.map(\.editedByPerson), [nil, true, nil], "what the person edited by hand is flagged")
        XCTAssertEqual(request.sources.count, 1, "the material goes along, so new cards can be based on it")
        XCTAssertEqual(request.cardCount, 3)
        XCTAssertTrue(request.existingFronts.isEmpty)
    }

    func testTheReplyReplacesTheListAndMarksWhatChanged() async throws {
        let (draft, _) = await reviewed([reply([
            GeneratedCard(front: "Front 1", back: "Back 1", sourcePage: 1),
            GeneratedCard(front: "Front 2", back: "Shorter 2", sourcePage: 2),
            GeneratedCard(front: "A brand new question", back: "Its answer", sourcePage: 7),
        ])])
        let ids = draft.cards.map(\.id)
        draft.toggle(ids[0])
        draft.refine("shorter, and add one on the Krebs cycle")
        await eventually("refined") { !draft.isBusy }

        XCTAssertEqual(draft.cards.count, 3, "card 3 was left out of the reply")
        XCTAssertEqual(draft.cards[0].id, ids[0])
        XCTAssertFalse(draft.cards[0].isSelected, "an unchanged card keeps being unticked")
        XCTAssertEqual(draft.cards[1].id, ids[1], "a changed card keeps its place")
        XCTAssertEqual(draft.cards[1].back, "Shorter 2")
        XCTAssertEqual(draft.changedIDs, [ids[1]])
        XCTAssertFalse(draft.cards[1].isAdded)
        XCTAssertTrue(draft.cards[2].isAdded, "new cards are marked added")
        XCTAssertTrue(draft.cards[2].isSelected)
        XCTAssertEqual(draft.cards[2].sourcePage, 7)
        XCTAssertFalse(draft.cards.contains { $0.id == ids[2] })
        draft.clearChanged()
        XCTAssertTrue(draft.changedIDs.isEmpty)
    }

    func testTheNameThePersonWroteIsKeptWhenTheModelSuggestsAnother() async {
        let (draft, _) = await reviewed([reply(name: "Something Else", DraftFixtures.cards(1...1))])
        draft.rename("Mine")
        draft.refine("anything")
        await eventually("refined") { !draft.isBusy }
        XCTAssertEqual(draft.name, "Mine")
    }

    func testRefineCanRenameADeckThePersonDidNotName() async {
        let (draft, _) = await reviewed([reply(name: "Better Name", [DraftFixtures.card(1)])], count: 1)
        draft.refine("rename it")
        await eventually("refined") { !draft.isBusy }
        XCTAssertEqual(draft.name, "Better Name")
        XCTAssertTrue(draft.isNameSuggested)
    }

    func testAFailedRefineLeavesTheCardsAsTheyWereAndCanBeTriedAgain() async {
        let (draft, generator) = await reviewed([
            [.event(.card(GeneratedCard(front: "x", back: "y", sourcePage: nil))), .fail(GenerationError.rateLimited(retryAfter: 4))],
            reply([DraftFixtures.card(1)]),
        ], count: 1)
        let before = draft.cards
        draft.refine("shorter")
        await eventually("failed") { draft.problem != nil }
        XCTAssertEqual(draft.cards, before, "a half answer never replaces the list")
        XCTAssertEqual(draft.problem?.fixes, [.tryAgain])
        XCTAssertEqual(draft.problem?.operation, .refine("shorter"))
        draft.retry()
        await eventually("retried") { !draft.isBusy }
        XCTAssertNil(draft.problem)
        XCTAssertEqual(generator.requests.count, 3)
        if case .refine(let instruction, _, _) = generator.requests[2].task { XCTAssertEqual(instruction, "shorter") } else { XCTFail("the same refine") }
    }

    func testAnEmptyAnswerToARefineIsNotAccepted() async {
        let (draft, _) = await reviewed([reply([])], count: 2)
        let before = draft.cards
        draft.refine("delete everything")
        await eventually("answered") { !draft.isBusy }
        XCTAssertEqual(draft.cards, before)
        XCTAssertEqual(draft.problem?.error, .badResponse)
    }

    func testRefineNeedsTextCardsAndAFinishedRun() async {
        let (draft, generator) = await reviewed([reply([DraftFixtures.card(1)])], count: 1)
        draft.refine("   ")
        XCTAssertEqual(generator.requests.count, 1, "blank asks nothing")
        let busy = GenerationDraft(plan: DraftFixtures.plan(ScriptedGenerator([[.hang]])), snapshot: DraftFixtures.snapshot())
        busy.start()
        busy.refine("shorter")
        XCTAssertEqual(busy.activeOperation, .generate, "not while cards are still arriving")
        busy.stop()
        await eventually("stopped") { !busy.isBusy }
    }

    // MARK: Rewriting one card

    func testRewritingACardAsksForOneNewCardForTheSamePage() async throws {
        let (draft, generator) = await reviewed([reply([GeneratedCard(front: "A fresh front", back: "A fresh back", sourcePage: 2)])])
        let id = draft.cards[1].id
        draft.toggle(draft.cards[0].id)
        draft.rewrite(id)
        XCTAssertEqual(draft.activeOperation, .rewrite(id))
        await eventually("rewritten") { !draft.isBusy }
        let request = try XCTUnwrap(generator.requests.last)
        guard case .replace(let card, let deckName) = request.task else { return XCTFail("a replace") }
        XCTAssertEqual(card.front, "Front 2")
        XCTAssertEqual(card.sourcePage, 2)
        XCTAssertEqual(deckName, "Cellular Respiration")
        XCTAssertEqual(request.cardCount, 1)
        XCTAssertEqual(request.existingFronts, ["Front 1", "Front 3"], "the deck's other fronts, to avoid repeats")

        XCTAssertEqual(draft.cards[1].id, id, "in place")
        XCTAssertEqual(draft.cards[1].front, "A fresh front")
        XCTAssertEqual(draft.cards[1].back, "A fresh back")
        XCTAssertEqual(draft.cards[1].sourcePage, 2)
        XCTAssertTrue(draft.cards[1].isSelected)
        XCTAssertFalse(draft.cards[0].isSelected, "the others are as they were")
        XCTAssertEqual(draft.changedIDs, [id])
        XCTAssertEqual(draft.cards.count, 3)
    }

    func testARewriteReplacesWhatThePersonEditedAndForgetsTheEdit() async {
        let (draft, _) = await reviewed([reply([GeneratedCard(front: "New", back: "New back", sourcePage: 1)])], count: 1)
        draft.setFront(draft.cards[0].id, "Hand edited")
        draft.rewrite(draft.cards[0].id)
        await eventually("rewritten") { !draft.isBusy }
        XCTAssertEqual(draft.cards[0].front, "New")
        XCTAssertFalse(draft.cards[0].isEditedByPerson)
    }

    func testAFailedRewriteLeavesTheCardAndCanBeTriedAgain() async {
        let (draft, generator) = await reviewed([[.fail(GenerationError.overloaded)], reply([GeneratedCard(front: "Fixed", back: "ok", sourcePage: 1)])], count: 1)
        let id = draft.cards[0].id
        draft.rewrite(id)
        await eventually("failed") { draft.problem != nil }
        XCTAssertEqual(draft.cards[0].front, "Front 1")
        XCTAssertEqual(draft.problem?.operation, .rewrite(id))
        draft.retry()
        await eventually("retried") { !draft.isBusy }
        XCTAssertEqual(draft.cards[0].front, "Fixed")
        XCTAssertEqual(generator.requests.count, 3)
    }

    func testOnlyOneThingAtATime() async {
        let gate = Gate()
        let (draft, generator) = await reviewed([[.wait(gate), .event(.card(DraftFixtures.card(9))), .event(.finished(nil))]], count: 2)
        draft.rewrite(draft.cards[0].id)
        await eventually("the rewrite is asked for") { generator.requests.count == 2 }
        draft.rewrite(draft.cards[1].id)
        draft.refine("shorter")
        draft.addMore(3)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(generator.requests.count, 2, "the first run and the one rewrite, and nothing else while it works")
        gate.open()
        await eventually("done") { !draft.isBusy }
    }

    // MARK: Merging

    func testMergeKeepsIdsAndTickedStateOfUnchangedCards() {
        var old = [DraftCard(front: "A", back: "1"), DraftCard(front: "B", back: "2")]
        old[0].isSelected = false
        old[1].isEditedByPerson = true
        let result = DraftMerge.apply(reply: [
            GeneratedCard(front: " a ", back: "1", sourcePage: nil),
            GeneratedCard(front: "B", back: "2", sourcePage: 4),
        ], to: old)
        XCTAssertEqual(result.cards.map(\.id), old.map(\.id))
        XCTAssertEqual(result.cards.map(\.isSelected), [false, true])
        XCTAssertEqual(result.cards.map(\.isEditedByPerson), [false, true], "untouched cards stay edited by hand")
        XCTAssertTrue(result.changed.isEmpty)
        XCTAssertTrue(result.added.isEmpty)
        XCTAssertEqual(result.cards[1].sourcePage, 4)
    }

    func testMergePairsExactMatchesBeforeChangedOnes() {
        let old = [DraftCard(front: "Same front", back: "old"), DraftCard(front: "Same front", back: "keep")]
        let result = DraftMerge.apply(reply: [
            GeneratedCard(front: "Same front", back: "keep", sourcePage: nil),
            GeneratedCard(front: "Same front", back: "new", sourcePage: nil),
        ], to: old)
        XCTAssertEqual(result.cards[0].id, old[1].id, "the exact match keeps its card")
        XCTAssertEqual(result.cards[1].id, old[0].id)
        XCTAssertEqual(result.changed, [old[0].id])
    }

    func testMergeDropsWhatTheReplyLeavesOutAndMarksNewCards() {
        let old = [DraftCard(front: "A", back: "1"), DraftCard(front: "B", back: "2")]
        let result = DraftMerge.apply(reply: [GeneratedCard(front: "C", back: "3", sourcePage: 9)], to: old)
        XCTAssertEqual(result.cards.count, 1)
        XCTAssertTrue(result.cards[0].isAdded)
        XCTAssertEqual(result.added, [result.cards[0].id])
        XCTAssertFalse(old.map(\.id).contains(result.cards[0].id))
    }
}

// MARK: - Prompts

final class DraftPromptTests: XCTestCase {
    private let cards = [
        RefineCard(front: "What is ATP?", back: "Energy currency", sourcePage: 4),
        RefineCard(front: "Where?", back: "Cytosol", sourcePage: nil, editedByPerson: true),
    ]

    func testARefineSaysWhatIsAskedShowsTheCardsAndWhatToKeep() {
        let text = GenerationPrompt.refineInstructions(instruction: "make the answers shorter", deckName: "Cells", cards: cards, hasSources: true)
        XCTAssertTrue(text.contains("“make the answers shorter”"))
        XCTAssertTrue(text.contains("“Cells”"))
        XCTAssertTrue(text.contains(#"{"back":"Energy currency","front":"What is ATP?","sourcePage":4}"#), text)
        XCTAssertTrue(text.contains(#""editedByPerson":true"#))
        XCTAssertFalse(text.contains(#""editedByPerson":false"#), "only said for cards edited by hand")
        XCTAssertTrue(text.contains("word for word"))
        XCTAssertTrue(text.contains("changed by the person by hand"))
        XCTAssertTrue(text.contains("unless the request is about it"))
        XCTAssertTrue(text.contains("the material above"))
        XCTAssertTrue(text.contains("Keep the deck name"))
    }

    func testARefineWithNoMaterialSaysToUseWhatIsWellKnown() {
        let text = GenerationPrompt.refineInstructions(instruction: "add 2", deckName: "Cells", cards: cards, hasSources: false)
        XCTAssertFalse(text.contains("the material above"))
        XCTAssertTrue(text.contains("well-established facts"))
    }

    func testAReplaceShowsTheCardAndItsPage() {
        let text = GenerationPrompt.replaceInstructions(card: cards[0], deckName: "Cells", hasSources: true)
        XCTAssertTrue(text.contains("What is ATP?"))
        XCTAssertTrue(text.contains("page 4"))
        XCTAssertTrue(text.contains("exactly one card"))
        XCTAssertTrue(text.contains("“Cells”"))
        let noPage = GenerationPrompt.replaceInstructions(card: cards[1], deckName: "Cells", hasSources: false)
        XCTAssertFalse(noPage.contains("page "))
        XCTAssertTrue(noPage.contains("well-established facts"))
    }

    func testTheTaskChangesTheLastBlockOfWhatIsSent() {
        let sources: [GenerationSource] = [.text(TextSource(text: "notes", name: nil))]
        var request = GenerationRequest(sources: sources, focus: "ATP", cardCount: 2, modelID: "m")
        let create = GenerationPrompt.instructions(for: request)
        XCTAssertTrue(create.hasPrefix("Make 2 flashcards from the material above."))

        request.task = .refine(instruction: "shorter", deckName: "Cells", cards: cards)
        let refine = GenerationPrompt.instructions(for: request)
        XCTAssertTrue(refine.hasPrefix("Here is the deck “Cells”"), refine)
        XCTAssertTrue(refine.contains("What matters to me:\nATP"), "the focus still goes along")
        XCTAssertFalse(refine.contains("Make 2 flashcards"))

        request.task = .replace(card: cards[0], deckName: "Cells")
        request.existingFronts = ["Where?"]
        let replace = GenerationPrompt.instructions(for: request)
        XCTAssertTrue(replace.contains("the person doesn't want this card"))
        XCTAssertTrue(replace.contains("Already in the deck (do not repeat these):\n- Where?"))
    }

    func testTheDocumentsAndPicturesStillComeFirst() {
        var request = GenerationRequest(sources: [.pdf(PDFSource(data: Data([1]), filename: "a.pdf", pageCount: 1))], cardCount: 1, modelID: "m")
        request.task = .replace(card: cards[0], deckName: "Cells")
        let parts = GenerationPrompt.parts(for: request)
        guard case .pdf = parts.first, case .text = parts.last else { return XCTFail("the PDF, then the instructions") }
    }

    func testRefineCardsAreEncodedWithoutTheFlagUnlessSet() throws {
        let plain = try JSONEncoder().encode(RefineCard(front: "a", back: "b", sourcePage: nil))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("editedByPerson"))
        let edited = try JSONEncoder().encode(RefineCard(front: "a", back: "b", sourcePage: 2, editedByPerson: true))
        XCTAssertTrue(String(decoding: edited, as: UTF8.self).contains(#""editedByPerson":true"#))
    }
}

// MARK: - From the composer

@MainActor
final class ComposerRunTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try PictureFixtures.tempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func rig(_ scripts: [[ScriptedGenerator.Step]]) async -> (ComposerRig, ScriptedGenerator) {
        let generator = ScriptedGenerator(scripts)
        return (await ComposerRig.make(directory: directory, generator: generator), generator)
    }

    func testPressingGenerateStartsADraftAndEmptiesTheForm() async throws {
        let (rig, generator) = await rig([DraftFixtures.run(cards: 1...2)])
        await rig.model.add([.text("notes about cells")])
        rig.model.focus = "the ATP counts"
        rig.model.choosePreset(10)
        let draft = try XCTUnwrap(rig.model.startRun(decks: []))
        XCTAssertTrue(rig.model.draft === draft)
        XCTAssertTrue(rig.model.items.isEmpty)
        XCTAssertEqual(rig.model.focus, "")
        XCTAssertEqual(rig.model.readiness, .needsInput)
        await eventually("the run") { !draft.isBusy }
        XCTAssertEqual(draft.cards.count, 2)
        XCTAssertEqual(generator.requests.first?.focus, "the ATP counts")
        XCTAssertEqual(generator.requests.first?.cardCount, 10)
        XCTAssertEqual(rig.model.draftBadge, "Draft")
    }

    func testNoRunUntilReadyAndNotTwiceAtOnce() async throws {
        let (rig, generator) = await rig([[.hang]])
        XCTAssertNil(rig.model.startRun(decks: []), "nothing to make cards from")
        rig.model.focus = "x"
        let draft = try XCTUnwrap(rig.model.startRun(decks: []))
        await eventually("the run is asked for") { generator.requests.count == 1 }
        rig.model.focus = "y"
        XCTAssertNil(rig.model.startRun(decks: []), "a draft is already there")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(generator.requests.count, 1)
        XCTAssertEqual(rig.model.draftBadge, "0/20")
        draft.stop()
        await eventually("stopped") { !draft.isBusy }
    }

    func testStartOverPutsBackWhatWasInTheForm() async throws {
        let (rig, _) = await rig([DraftFixtures.run(cards: 1...2)])
        await rig.model.add([.text("notes about cells")])
        rig.model.focus = "the ATP counts"
        rig.model.style = .cloze
        rig.model.languageName = "German"
        rig.model.choosePreset(30)
        rig.model.destination = .deck(UUID())
        let draft = try XCTUnwrap(rig.model.startRun(decks: []))
        await eventually("the run") { !draft.isBusy }

        rig.model.startOver()
        XCTAssertNil(rig.model.draft)
        XCTAssertEqual(rig.model.items.count, 1)
        XCTAssertEqual(rig.model.focus, "the ATP counts")
        XCTAssertEqual(rig.model.style, .cloze)
        XCTAssertEqual(rig.model.languageName, "German")
        XCTAssertEqual(rig.model.cardCount, 30)
        XCTAssertFalse(rig.model.isCustomCount)
        XCTAssertEqual(rig.model.readiness, .ready)
        XCTAssertNil(rig.model.draftBadge)
    }

    func testStartOverWhileCardsAreArrivingStopsTheRun() async throws {
        let (rig, _) = await rig([[.event(.card(DraftFixtures.card(1))), .hang]])
        rig.model.focus = "x"
        let draft = try XCTUnwrap(rig.model.startRun(decks: []))
        await eventually("a card") { draft.cards.count == 1 }
        XCTAssertEqual(rig.model.draftBadge, "1/20")
        rig.model.startOver()
        await eventually("stopped") { !draft.isBusy }
        XCTAssertNil(rig.model.draft)
        XCTAssertEqual(rig.model.focus, "x")
    }

    func testDiscardingLeavesTheFormEmpty() async throws {
        let (rig, _) = await rig([DraftFixtures.run()])
        rig.model.focus = "x"
        let draft = try XCTUnwrap(rig.model.startRun(decks: []))
        await eventually("the run") { !draft.isBusy }
        XCTAssertTrue(rig.model.hasUnsavedDraft)
        rig.model.discardDraft()
        XCTAssertNil(rig.model.draft)
        XCTAssertFalse(rig.model.hasUnsavedDraft)
        XCTAssertEqual(rig.model.focus, "")
        XCTAssertTrue(rig.model.items.isEmpty)
    }

    func testSavingEndsTheDraftAndTheFormStaysEmpty() async throws {
        let (rig, _) = await rig([DraftFixtures.run(cards: 1...2)])
        rig.model.focus = "x"
        let draft = try XCTUnwrap(rig.model.startRun(decks: []))
        await eventually("the run") { !draft.isBusy }
        let store = PreviewData.store(decks: [])
        let id = draft.saveAsNewDeck(in: store)
        XCTAssertNotNil(id)
        XCTAssertNil(rig.model.draft, "the draft is over")
        XCTAssertFalse(rig.model.hasUnsavedDraft)
        XCTAssertEqual(rig.model.readiness, .needsInput)
    }

    func testQuittingAsksOnlyWhenThereIsSomethingToLose() async throws {
        let (rig, _) = await rig([[.hang], DraftFixtures.run()])
        XCTAssertFalse(rig.model.hasUnsavedDraft)
        rig.model.focus = "x"
        let draft = try XCTUnwrap(rig.model.startRun(decks: []))
        XCTAssertTrue(rig.model.hasUnsavedDraft, "a run in progress counts")
        draft.stop()
        await eventually("stopped") { !draft.isBusy }
        XCTAssertFalse(rig.model.hasUnsavedDraft, "a draft with no cards has nothing to lose")
    }

    func testTheDraftKnowsWhereTheCardsWereAskedToGo() async throws {
        let (rig, _) = await rig([DraftFixtures.run()])
        rig.model.focus = "x"
        let deck = Deck(name: "Bio")
        rig.model.destination = .deck(deck.id)
        let draft = try XCTUnwrap(rig.model.startRun(decks: [deck]))
        XCTAssertEqual(draft.plan.destination, .deck(deck.id))
        await eventually("the run") { !draft.isBusy }
    }
}

import XCTest

/// "Generate…" inside a deck (FLAS-51): opening the form for that deck, passing its fronts along, keeping
/// the deck's name, and saving into it.

@MainActor
final class DeckGenerateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try PictureFixtures.tempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func makeDeck(name: String = "Spanish A2", cards: Int = 3, color: DeckColor = .green) -> Deck {
        Deck(name: name, color: color, cards: (1...max(cards, 1)).prefix(cards).map { Card(front: "Front \($0)", back: "Back \($0)") })
    }

    private func rig(_ scripts: [[ScriptedGenerator.Step]] = [], anthropic: String? = AIFixtures.anthropicDefault) async -> (ComposerRig, ScriptedGenerator) {
        let generator = ScriptedGenerator(scripts)
        return (await ComposerRig.make(directory: directory, anthropic: anthropic, generator: generator), generator)
    }

    // MARK: Opening the form

    func testTheButtonIsAvailableOnlyWithAProviderAndNoDraftWaiting() async throws {
        let (none, _) = await rig(anthropic: nil)
        XCTAssertEqual(none.model.deckGenerateAvailability, .needsProvider)
        XCTAssertEqual(DeckGenerateAvailability.needsProvider.help, "Set up an AI provider in Settings > AI first.")

        let (ready, _) = await rig([[.hang]])
        XCTAssertEqual(ready.model.deckGenerateAvailability, .available)
        ready.model.focus = "x"
        let draft = try XCTUnwrap(ready.model.startRun(decks: []))
        XCTAssertEqual(ready.model.deckGenerateAvailability, .draftInProgress)
        XCTAssertEqual(DeckGenerateAvailability.draftInProgress.help, "Save or discard the draft in Create with AI first.")
        draft.stop()
        await eventually("stopped") { !draft.isBusy }
        ready.model.discardDraft()
        XCTAssertEqual(ready.model.deckGenerateAvailability, .available)
    }

    func testTheFormOpensWithThatDeckChosenAndKeepsWhatWasThere() async {
        let (rig, _) = await rig()
        let deck = makeDeck()
        rig.model.focus = "the ATP counts"
        rig.model.style = .cloze
        await rig.model.add([.text("notes")])
        XCTAssertTrue(rig.model.prepareForDeck(deck.id))
        XCTAssertEqual(rig.model.destination, .deck(deck.id))
        XCTAssertEqual(rig.model.resolvedDestination(in: [deck]), .deck(deck.id), "the form shows it in Put cards in")
        XCTAssertEqual(rig.model.focus, "the ATP counts")
        XCTAssertEqual(rig.model.style, .cloze)
        XCTAssertEqual(rig.model.items.count, 1)
    }

    func testNothingChangesWhenTheFormCannotBeUsed() async throws {
        let (none, _) = await rig(anthropic: nil)
        XCTAssertFalse(none.model.prepareForDeck(UUID()))
        XCTAssertEqual(none.model.destination, .newDeck)

        let (busy, _) = await rig([[.hang]])
        busy.model.focus = "x"
        let draft = try XCTUnwrap(busy.model.startRun(decks: []))
        XCTAssertFalse(busy.model.prepareForDeck(UUID()))
        XCTAssertEqual(busy.model.destination, .newDeck)
        draft.stop()
        await eventually("stopped") { !draft.isBusy }
    }

    // MARK: The deck's cards go along

    func testTheRequestCarriesTheDecksFrontsAndThePromptTheLastThreeHundred() async throws {
        let (rig, _) = await rig()
        let deck = makeDeck(cards: 400)
        rig.model.focus = "more"
        rig.model.prepareForDeck(deck.id)
        let request = try XCTUnwrap(rig.model.request(decks: [deck]))
        XCTAssertEqual(request.existingFronts.count, 400)
        XCTAssertEqual(request.existingFronts.first, "Front 1")

        let text = GenerationPrompt.instructions(for: request)
        XCTAssertTrue(text.contains("Already in the deck (do not repeat these):"))
        XCTAssertTrue(text.contains("- Front 400"))
        XCTAssertTrue(text.contains("- Front 101\n"), "the last 300 start here")
        XCTAssertFalse(text.contains("- Front 100\n"))
        XCTAssertEqual(text.components(separatedBy: "\n- Front ").count - 1, 300)
    }

    func testAShortDeckPassesAllItsFronts() async throws {
        let (rig, _) = await rig()
        let deck = makeDeck(cards: 3)
        rig.model.focus = "more"
        rig.model.prepareForDeck(deck.id)
        XCTAssertEqual(try XCTUnwrap(rig.model.request(decks: [deck])).existingFronts, ["Front 1", "Front 2", "Front 3"])
    }

    // MARK: The plan

    func testThePlanNamesTheDeckItsCardsAreFor() async throws {
        let (rig, _) = await rig()
        let deck = makeDeck(name: "Spanish A2", color: .orange)
        rig.model.focus = "more"
        rig.model.prepareForDeck(deck.id)
        let plan = try XCTUnwrap(rig.model.plan(decks: [deck]))
        XCTAssertEqual(plan.targetDeck, TargetDeck(id: deck.id, name: "Spanish A2", color: .orange))
        XCTAssertEqual(plan.destination, .deck(deck.id))

        let gone = try XCTUnwrap(rig.model.plan(decks: []))
        XCTAssertNil(gone.targetDeck, "the deck was deleted")
        XCTAssertEqual(gone.destination, .newDeck)

        rig.model.destination = .newDeck
        XCTAssertNil(try XCTUnwrap(rig.model.plan(decks: [deck])).targetDeck)
    }

    // MARK: The draft keeps the deck's name

    private func targetDraft(_ scripts: [[ScriptedGenerator.Step]], deck: Deck, count: Int = 3) -> (GenerationDraft, ScriptedGenerator) {
        let generator = ScriptedGenerator(scripts)
        var plan = DraftFixtures.plan(generator, count: count)
        plan.destination = .deck(deck.id)
        plan.targetDeck = TargetDeck(id: deck.id, name: deck.name, color: deck.color)
        return (GenerationDraft(plan: plan, snapshot: DraftFixtures.snapshot()), generator)
    }

    func testTheNameAndColorAreTheDecksAndNothingSuggestsAnother() async {
        let deck = makeDeck(name: "Spanish A2", color: .purple)
        let (draft, _) = targetDraft([DraftFixtures.run(name: "Something The Model Made Up")], deck: deck)
        XCTAssertEqual(draft.name, "Spanish A2", "there from the start")
        XCTAssertEqual(draft.color, .purple)
        XCTAssertTrue(draft.isNameFixed)
        draft.start()
        await eventually("the run") { !draft.isBusy }
        XCTAssertEqual(draft.name, "Spanish A2")
        XCTAssertFalse(draft.isNameSuggested, "no suggested name step")
        draft.rename("Another")
        draft.setColor(.orange)
        XCTAssertEqual(draft.name, "Spanish A2")
        XCTAssertEqual(draft.color, .purple)
    }

    func testARefineAsksUsingTheDecksNameAndKeepsIt() async throws {
        let deck = makeDeck(name: "Spanish A2")
        let (draft, generator) = targetDraft([DraftFixtures.run(cards: 1...2), [.event(.deckName("Renamed")), .event(.card(DraftFixtures.card(1))), .event(.card(DraftFixtures.card(2))), .event(.finished(nil))]], deck: deck, count: 2)
        draft.start()
        await eventually("the run") { !draft.isBusy }
        draft.refine("shorter")
        await eventually("refined") { !draft.isBusy }
        guard case .refine(_, let deckName, _) = try XCTUnwrap(generator.requests.last).task else { return XCTFail("a refine") }
        XCTAssertEqual(deckName, "Spanish A2")
        XCTAssertEqual(draft.name, "Spanish A2")
    }

    func testADraftForANewDeckStillSuggestsAndRenames() async {
        let (draft, _) = (GenerationDraft(plan: DraftFixtures.plan(ScriptedGenerator([DraftFixtures.run()]), count: 3), snapshot: DraftFixtures.snapshot()), 0)
        XCTAssertFalse(draft.isNameFixed)
        draft.start()
        await eventually("the run") { !draft.isBusy }
        XCTAssertTrue(draft.isNameSuggested)
        draft.rename("Mine")
        XCTAssertEqual(draft.name, "Mine")
    }

    // MARK: Saving into the deck

    func testAddToTheDeckAppendsTheTickedCardsAndLeavesTheDeckAsItIs() async throws {
        let deck = makeDeck(name: "Spanish A2", cards: 2, color: .green)
        let other = makeDeck(name: "Other", cards: 1)
        let store = PreviewData.store(decks: [other, deck])
        let (draft, _) = targetDraft([DraftFixtures.run(cards: 1...3)], deck: deck)
        draft.start()
        await eventually("the run") { !draft.isBusy }
        draft.toggle(draft.cards[1].id)
        var closed = false
        draft.onClose = { closed = true }

        let id = draft.saveToTargetDeck(in: store)
        XCTAssertEqual(id, deck.id, "so the deck is selected")
        let saved = try XCTUnwrap(store.decks.first { $0.id == deck.id })
        XCTAssertEqual(saved.cards.map(\.front), ["Front 1", "Front 2", "Front 1", "Front 3"], "after the 2 it had; the unticked one left out")
        XCTAssertEqual(saved.name, "Spanish A2")
        XCTAssertEqual(saved.color, .green)
        XCTAssertEqual(store.decks.count, 2)
        XCTAssertEqual(store.decks.first { $0.id == other.id }?.cards.count, 1)
        XCTAssertTrue(closed)
    }

    func testSavingToTheTargetNeedsOneAndTheDeckToStillBeThere() async throws {
        let deck = makeDeck()
        let store = PreviewData.store(decks: [])
        let (draft, _) = targetDraft([DraftFixtures.run()], deck: deck)
        draft.start()
        await eventually("the run") { !draft.isBusy }
        XCTAssertNil(draft.saveToTargetDeck(in: store), "the deck was deleted meanwhile")
        XCTAssertFalse(draft.cards.isEmpty, "the draft is kept")
        let newID = draft.saveAsNewDeck(in: store)
        XCTAssertNotNil(newID, "and can still become a deck of its own, with the same name")
        XCTAssertEqual(store.decks.first?.name, "Spanish A2")

        let (plain, _) = (GenerationDraft(plan: DraftFixtures.plan(ScriptedGenerator([DraftFixtures.run()]), count: 3), snapshot: DraftFixtures.snapshot()), 0)
        XCTAssertNil(plain.saveToTargetDeck(in: store), "a draft for a new deck has no target")
    }

    // MARK: End to end from the composer

    func testFromGenerateInADeckToCardsInThatDeck() async throws {
        let (rig, generator) = await rig([DraftFixtures.run(cards: 1...3)])
        let deck = makeDeck(name: "Spanish A2", cards: 2)
        let store = PreviewData.store(decks: [deck])
        rig.model.prepareForDeck(deck.id)
        rig.model.focus = "verbs"
        let draft = try XCTUnwrap(rig.model.startRun(decks: store.decks))
        await eventually("the run") { !draft.isBusy }
        XCTAssertEqual(draft.name, "Spanish A2")
        XCTAssertEqual(generator.requests.first?.existingFronts, ["Front 1", "Front 2"])
        XCTAssertEqual(rig.model.destination, .newDeck, "the form is empty again")

        XCTAssertEqual(draft.saveToTargetDeck(in: store), deck.id)
        XCTAssertNil(rig.model.draft)
        XCTAssertEqual(store.decks[0].cards.count, 5)
    }
}

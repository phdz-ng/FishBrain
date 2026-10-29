import AppKit
import SwiftUI
import XCTest

/// Editing the Now showing card in place (FLAS-84): the edit itself (FLAS-85), holding the card while
/// editing and throwing the draft away on the way out (FLAS-86), the table and undo (FLAS-87), and the
/// keyboard and VoiceOver (FLAS-88).
@MainActor
final class PreviewEditTests: XCTestCase {
    private var directory: URL!
    private var store: DeckStore!
    private var deck: Deck!
    private var announcements: [String] = []
    private var edit: PreviewCardEdit!
    /// Ten seconds into slot 11: card 12 of 48 in the clock-based rotation.
    private let t = Date(timeIntervalSince1970: 11 * 300 + 10)
    private let image = CardImage(fileName: "AB.jpg", altText: "a red door")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        store = DeckStore(storage: DeckStorage(directory: directory), debounce: .milliseconds(10), onSaved: {})
        var cards = (1...48).map { Card(front: "f\($0)", back: "b\($0)") }
        cards[11].frontImage = image
        deck = store.add(Deck(name: "Spanish", cards: cards))
        announcements = []
        edit = PreviewCardEdit { [unowned self] in self.announcements.append($0) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var currentDeck: Deck { store.decks.first { $0.id == deck.id }! }

    private func showing(_ state: PlaybackState = PlaybackState(), at date: Date? = nil) throws -> NowShowing {
        try XCTUnwrap(NowShowing.make(deck: currentDeck, state: state, at: date ?? t))
    }

    private func stored(_ showing: NowShowing) -> Card? { store.card(showing.card.id, in: deck.id) }

    // MARK: Starting (FLAS-85)

    func testEditingStartsOnTheSideShowing() throws {
        let front = try showing()
        edit.begin(front)
        XCTAssertEqual(edit.draft?.side, .front)
        XCTAssertEqual(edit.text, "f12")

        let flipped = CardScheduler().flipping(PlaybackState(), in: currentDeck, at: t)
        edit.begin(try showing(flipped))
        XCTAssertEqual(edit.draft?.side, .back)
        XCTAssertEqual(edit.text, "b12")
        XCTAssertEqual(edit.draft?.held.isFlipped, true)
    }

    func testASingleClickFlipsAndADoubleClickOnTheTextEditsWithoutFlipping() {
        XCTAssertEqual(PreviewClick.outcome(clickCount: 1, onText: false, hasCard: true), .flipAfterDoubleClickInterval)
        XCTAssertEqual(PreviewClick.outcome(clickCount: 1, onText: true, hasCard: true), .flipAfterDoubleClickInterval,
                       "the first click of a double click only sets up a flip, which the second calls off")
        XCTAssertEqual(PreviewClick.outcome(clickCount: 2, onText: true, hasCard: true), .edit)
        XCTAssertEqual(PreviewClick.outcome(clickCount: 2, onText: false, hasCard: true), .ignore, "away from the text")
        XCTAssertEqual(PreviewClick.outcome(clickCount: 2, onText: true, hasCard: false), .ignore, "no card")
        XCTAssertEqual(PreviewClick.outcome(clickCount: 3, onText: true, hasCard: true), .ignore)
    }

    func testReturnSavesShiftReturnAddsALineAndEscCancels() {
        let newline = #selector(NSResponder.insertNewline(_:))
        XCTAssertEqual(PreviewFieldKey.action(for: newline, shift: false), .save)
        XCTAssertEqual(PreviewFieldKey.action(for: newline, shift: true), .newLine)
        XCTAssertEqual(PreviewFieldKey.action(for: #selector(NSResponder.insertLineBreak(_:)), shift: false), .newLine)
        XCTAssertEqual(PreviewFieldKey.action(for: #selector(NSResponder.cancelOperation(_:)), shift: false), .cancel)
        XCTAssertNil(PreviewFieldKey.action(for: #selector(NSResponder.deleteBackward(_:)), shift: false))
    }

    // MARK: Saving and cancelling (FLAS-85, FLAS-87)

    func testSaveTrimsWritesAndGoesBackToTheLiveCard() throws {
        let card = try showing()
        edit.begin(card)
        edit.text = "  la puerta \n"
        XCTAssertTrue(edit.save(to: store))
        XCTAssertEqual(stored(card)?.front, "la puerta")
        XCTAssertEqual(stored(card)?.back, "b12", "only the side being edited changes")
        XCTAssertFalse(edit.isEditing)
        XCTAssertEqual(edit.lastEnding, .saved)
        XCTAssertEqual(announcements, ["Saved"])
    }

    func testAnEmptyFrontIsRefusedAndEditingCarriesOn() throws {
        let card = try showing()
        edit.begin(card)
        edit.text = "  \n "
        XCTAssertFalse(edit.save(to: store))
        XCTAssertTrue(edit.isEditing)
        XCTAssertEqual(edit.draft?.isRefused, true)
        XCTAssertEqual(stored(card)?.front, "f12")
        XCTAssertTrue(announcements.isEmpty)

        edit.text = "x"
        XCTAssertEqual(edit.draft?.isRefused, false, "typing clears the warning")
    }

    func testAnEmptyBackCanBeSaved() throws {
        let flipped = CardScheduler().flipping(PlaybackState(), in: currentDeck, at: t)
        let card = try showing(flipped)
        edit.begin(card)
        edit.text = ""
        XCTAssertTrue(edit.save(to: store))
        XCTAssertEqual(stored(card)?.back, "")
    }

    func testCancelKeepsTheSavedText() throws {
        let card = try showing()
        edit.begin(card)
        edit.text = "something else"
        edit.cancel()
        XCTAssertFalse(edit.isEditing)
        XCTAssertEqual(stored(card)?.front, "f12")
        XCTAssertEqual(edit.lastEnding, .cancelled)
        XCTAssertEqual(announcements, ["Cancelled"])
    }

    func testASaveIsOneUndoStep() throws {
        let undo = UndoManager()
        store.undoManager = undo
        let card = try showing()
        edit.begin(card)
        edit.text = "la puerta"
        edit.save(to: store)
        XCTAssertEqual(undo.undoActionName, "Edit Card")

        undo.undo()
        XCTAssertEqual(stored(card)?.front, "f12")
        undo.redo()
        XCTAssertEqual(stored(card)?.front, "la puerta")
        undo.undo()
        XCTAssertEqual(stored(card)?.front, "f12")
        XCTAssertFalse(undo.canUndo, "one step, not one per keystroke")
    }

    func testSavingUnchangedTextLeavesNothingToUndo() throws {
        let undo = UndoManager()
        store.undoManager = undo
        edit.begin(try showing())
        edit.save(to: store)
        XCTAssertFalse(undo.canUndo)
    }

    func testSavingChangesNothingButTheText() throws {
        let playback = PlaybackStore(storage: PlaybackStorage(directory: directory), onSaved: {})
        playback.flip(currentDeck, at: t)
        playback.grade(.good, currentDeck, at: t)
        let before = playback.state(for: deck.id)
        let card = try showing()
        let index = currentDeck.cards.firstIndex { $0.id == card.card.id }

        edit.begin(card)
        edit.text = "la puerta"
        edit.save(to: store)

        XCTAssertEqual(playback.state(for: deck.id), before, "review state, flips and skips are untouched")
        XCTAssertEqual(stored(card)?.frontImage, image, "the picture stays")
        XCTAssertEqual(currentDeck.cards.firstIndex { $0.id == card.card.id }, index, "so does its place in the deck")
    }

    // MARK: Holding the card (FLAS-86)

    func testThePreviewHoldsTheCardWhileTheClockMovesOn() throws {
        let card = try showing()
        edit.begin(card)
        let later = try showing(at: t.addingTimeInterval(3 * 300))
        XCTAssertNotEqual(later.card.id, card.card.id, "the rotation has moved on")
        XCTAssertEqual(edit.displayed(live: later, deckID: deck.id)?.card.id, card.card.id)
        XCTAssertEqual(edit.displayed(live: later, deckID: UUID())?.card.id, later.card.id, "only for this deck")
    }

    func testAfterSaveOrCancelThePreviewShowsTheLiveCardAgain() throws {
        let later = try showing(at: t.addingTimeInterval(600))
        edit.begin(try showing())
        edit.cancel()
        XCTAssertEqual(edit.displayed(live: later, deckID: deck.id), later)

        edit.begin(try showing())
        edit.text = "new"
        edit.save(to: store)
        XCTAssertEqual(edit.displayed(live: later, deckID: deck.id), later)
    }

    func testDeletingTheCardEndsEditingUnsaved() throws {
        let card = try showing()
        edit.begin(card)
        edit.endIfStale(deck: currentDeck)
        XCTAssertTrue(edit.isEditing, "nothing has changed yet")

        store.deleteCards([card.card.id], in: deck.id)
        edit.endIfStale(deck: currentDeck)
        XCTAssertFalse(edit.isEditing)
        XCTAssertEqual(edit.lastEnding, .discarded)
    }

    func testSwitchingDecksThrowsTheDraftAway() throws {
        let card = try showing()
        let other = store.add(Deck(name: "French", cards: [Card(front: "a", back: "b")]))
        edit.begin(card)
        edit.text = "unsaved"
        edit.endIfStale(deck: other)
        XCTAssertFalse(edit.isEditing)
        XCTAssertEqual(stored(card)?.front, "f12")
        XCTAssertTrue(announcements.isEmpty, "a discard isn't announced")
    }

    func testOpeningASubjectLearnOrASprintThrowsTheDraftAway() throws {
        // The deck view goes away (or shows no deck) for a subject page, Learn and a sprint.
        let card = try showing()
        edit.begin(card)
        edit.text = "unsaved"
        edit.endIfStale(deck: nil)
        XCTAssertFalse(edit.isEditing)
        XCTAssertEqual(stored(card)?.front, "f12")
    }

    func testClosingTheWindowThrowsTheDraftAway() throws {
        let card = try showing()
        edit.begin(card)
        edit.text = "unsaved"
        edit.discard()
        XCTAssertFalse(edit.isEditing)
        XCTAssertEqual(edit.lastEnding, .discarded)
        XCTAssertEqual(stored(card)?.front, "f12")
    }

    // MARK: The table (FLAS-87)

    func testTheRowShowsTheDraftWithoutChangingTheStoredCard() throws {
        let card = try showing()
        edit.begin(card)
        edit.text = "la puer"
        XCTAssertEqual(edit.draftText(for: card.card.id, side: .front), "la puer")
        XCTAssertNil(edit.draftText(for: card.card.id, side: .back), "only the side being edited")
        XCTAssertNil(edit.draftText(for: UUID(), side: .front), "only that card")
        XCTAssertEqual(stored(card)?.front, "f12")

        edit.cancel()
        XCTAssertNil(edit.draftText(for: card.card.id, side: .front), "back to the saved text")
    }

    // MARK: The panel

    private func fittingSize<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: view.environment(\.accentChoice, .default).preferredColorScheme(.dark)).fittingSize
    }

    func testThePanelKeepsItsHeightWhileEditing() throws {
        let card = try showing()
        let resting = fittingSize(NowShowingPanel(
            deck: currentDeck, state: PlaybackState(), onFlip: {}, onSkip: {}, studySummary: { _ in .sample }
        ))
        let editing = PreviewCardEdit()
        editing.begin(card)
        let editingSize = fittingSize(NowShowingPanel(
            deck: currentDeck, state: PlaybackState(), onFlip: {}, onSkip: {}, studySummary: { _ in .sample }, edit: editing
        ))
        XCTAssertEqual(resting.height, editingSize.height, accuracy: 0.5)
        XCTAssertEqual(editingSize.width, NowShowingPanel.side, accuracy: 0.5)
    }

    func testTheLabelAboveTheCardSaysWhenItIsBeingEdited() {
        XCTAssertEqual(NowShowingPanel.label(isEditing: false), "Now showing")
        XCTAssertEqual(NowShowingPanel.label(isEditing: true), "Editing card")
    }

    // MARK: Keyboard and VoiceOver (FLAS-88)

    func testTheCardOffersEditingToVoiceOverAndTheContextMenu() {
        XCTAssertEqual(NowShowingPanel.editActionName, "Edit card")
        XCTAssertEqual(NowShowingPanel.accessibilityHint(hasCard: true), "Flips the card. Actions available.")
        XCTAssertEqual(NowShowingPanel.accessibilityHint(hasCard: false), "Flips the card")
        XCTAssertEqual(NowShowingPanel.editMenuTitle(isFlipped: false), "Edit Front")
        XCTAssertEqual(NowShowingPanel.editMenuTitle(isFlipped: true), "Edit Back")
    }

    func testTheFieldIsReadAsFrontOrBack() {
        XCTAssertEqual(PreviewTextField.accessibilityLabel(.front), "Front")
        XCTAssertEqual(PreviewTextField.accessibilityLabel(.back), "Back")
    }

    func testSaveAndCancelAreAnnouncedButADiscardIsNot() {
        XCTAssertEqual(PreviewCardEdit.announcement(for: .saved), "Saved")
        XCTAssertEqual(PreviewCardEdit.announcement(for: .cancelled), "Cancelled")
        XCTAssertNil(PreviewCardEdit.announcement(for: .discarded))
    }

    func testTheEditingFieldIsAFocusedTextFieldForVoiceOver() throws {
        let card = try showing()
        let editing = PreviewCardEdit()
        editing.begin(card)
        let host = NSHostingView(rootView: NowShowingPanel(
            deck: currentDeck, state: PlaybackState(), onFlip: {}, onSkip: {}, edit: editing
        ).environment(\.accentChoice, .default))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(Self.firstTextView(in: host))
        XCTAssertEqual(field.accessibilityRole(), .textField)
        XCTAssertEqual(field.accessibilityLabel(), "Front")
        XCTAssertEqual(field.string, "f12")
        XCTAssertEqual(field.alignment, .center)
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for child in view.subviews { if let found = firstTextView(in: child) { return found } }
        return nil
    }
}

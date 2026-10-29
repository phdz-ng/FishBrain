import AppKit
import SwiftUI

/// Editing the Now showing card in place: which side is being edited, the draft, and the card as it was
/// when editing began.
///
/// The rotation can't be paused (`CardScheduler` works it out from the clock, and the widget and notch
/// read the same state from the app group), so the preview holds on to the card itself while the
/// rotation carries on everywhere else. Nothing here touches `PlaybackState`. Only `save` writes, through
/// `DeckStore`; every other way out of editing throws the draft away, with no prompt.
@MainActor
final class PreviewCardEdit: ObservableObject {
    struct Draft: Equatable {
        /// The card being edited, as the preview showed it when editing began, turned to the side being
        /// edited. The preview keeps showing this while the live card moves on.
        var held: NowShowing
        var side: CardSide
        var text: String
        /// Save was refused (an empty front); cleared by typing.
        var isRefused = false

        var deckID: Deck.ID { held.deckID }
        var cardID: Card.ID { held.card.id }
        /// The side's text as it is stored.
        var savedText: String { held.card.text(on: side) }
    }

    enum Ending: Equatable {
        case saved, cancelled
        /// Left some other way: another deck or subject, Learn, a sprint, the window closing, the table,
        /// or the card being deleted.
        case discarded
    }

    @Published private(set) var draft: Draft?
    /// How the last edit ended.
    private(set) var lastEnding: Ending?
    /// What VoiceOver hears when editing ends.
    private let announce: @MainActor (String) -> Void

    nonisolated init(announce: @escaping @MainActor (String) -> Void = PreviewCardEdit.postAnnouncement) {
        self.announce = announce
    }

    var isEditing: Bool { draft != nil }

    func isEditing(in deckID: Deck.ID) -> Bool { draft?.deckID == deckID }

    /// Starts editing the card the preview shows, on the side showing unless another is asked for.
    func begin(_ showing: NowShowing, side: CardSide? = nil) {
        let side = side ?? (showing.isFlipped ? .back : .front)
        var held = showing
        held.isFlipped = side == .back
        draft = Draft(held: held, side: side, text: held.card.text(on: side))
    }

    /// The draft's text, for the field. Typing clears a refused Save.
    var text: String {
        get { draft?.text ?? "" }
        set {
            guard draft != nil, draft?.text != newValue else { return }
            draft?.text = newValue
            draft?.isRefused = false
        }
    }

    /// What the preview shows for a deck: the held card while it is being edited, otherwise the live one.
    func displayed(live: NowShowing?, deckID: Deck.ID) -> NowShowing? {
        if let draft, draft.deckID == deckID { return draft.held }
        return live
    }

    /// The text a table row shows for a side: the draft while that side is being edited here.
    func draftText(for cardID: Card.ID, side: CardSide) -> String? {
        guard let draft, draft.cardID == cardID, draft.side == side else { return nil }
        return draft.text
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A card needs a front; a blank back is allowed, as in the table.
    static func canSave(_ text: String, side: CardSide) -> Bool {
        side == .back || !trimmed(text).isEmpty
    }

    /// Writes the draft, trimmed, as one undo step and goes back to the live card. An empty front is
    /// refused: editing carries on with `isRefused` set.
    @discardableResult
    func save(to store: DeckStore) -> Bool {
        guard let draft else { return false }
        guard Self.canSave(draft.text, side: draft.side) else {
            self.draft?.isRefused = true
            return false
        }
        store.setText(Self.trimmed(draft.text), on: draft.side, for: draft.cardID, in: draft.deckID)
        end(.saved)
        return true
    }

    /// Esc or Cancel: the card keeps its saved text.
    func cancel() { end(.cancelled) }

    /// Any other way out of editing: the draft is thrown away and the card keeps its saved text.
    func discard() { end(.discarded) }

    /// Ends editing without saving when what it was on has gone: another deck (or none) is on screen,
    /// or the card has been deleted.
    func endIfStale(deck: Deck?) {
        guard let draft else { return }
        guard let deck, deck.id == draft.deckID, deck.cards.contains(where: { $0.id == draft.cardID }) else {
            discard()
            return
        }
    }

    /// "Saved" and "Cancelled" are spoken; a discard isn't, since the user has already moved on.
    static func announcement(for ending: Ending) -> String? {
        switch ending {
        case .saved: "Saved"
        case .cancelled: "Cancelled"
        case .discarded: nil
        }
    }

    private func end(_ ending: Ending) {
        guard draft != nil else { return }
        draft = nil
        lastEnding = ending
        if let message = Self.announcement(for: ending) { announce(message) }
    }

    static func postAnnouncement(_ message: String) {
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(
            element: window, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}

/// Tells a single click on the card (flip it, once the double-click interval has passed without a second
/// click) from a double click on its text (edit, without flipping).
enum PreviewClick: Equatable {
    case flipAfterDoubleClickInterval
    /// Calls off the flip the first click set up.
    case edit
    case ignore

    static func outcome(clickCount: Int, onText: Bool, hasCard: Bool) -> PreviewClick {
        switch clickCount {
        case ...1: .flipAfterDoubleClickInterval
        case 2: onText && hasCard ? .edit : .ignore
        default: .ignore
        }
    }

    /// The click count of the event being handled; 1 for anything that isn't a mouse click (a
    /// VoiceOver press, say), where asking an event for its click count would throw.
    @MainActor
    static var currentClickCount: Int {
        guard let event = NSApp?.currentEvent else { return 1 }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return event.clickCount
        default:
            return 1
        }
    }
}

/// What a key does in the editing field: Return saves, Shift+Return starts a new line, Esc cancels.
enum PreviewFieldKey: Equatable {
    case save, newLine, cancel

    /// The text view's command for a key press, and whether Shift was down. nil leaves the command to
    /// the text view.
    static func action(for selector: Selector, shift: Bool) -> PreviewFieldKey? {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): shift ? .newLine : .save
        case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): .newLine
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)): .cancel
        default: nil
        }
    }
}

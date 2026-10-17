import Foundation

/// Text and selection rules for the main window, kept free of UI so they can be unit tested.
enum DeckSummary {
    /// "48 cards, showing in 2 widgets and the notch", or "48 cards, 3 due, showing in the notch" when
    /// graded cards have come due.
    static func subtitle(cardCount: Int, widgetCount: Int, showsInNotch: Bool, dueCount: Int = 0) -> String {
        var cards = cardCount == 1 ? "1 card" : "\(cardCount) cards"
        if dueCount > 0 { cards += ", \(dueCount) due" }
        var places: [String] = []
        if widgetCount > 0 {
            places.append(widgetCount == 1 ? "1 widget" : "\(widgetCount) widgets")
        }
        if showsInNotch {
            places.append("the notch")
        }
        guard !places.isEmpty else { return cards }
        return "\(cards), showing in \(places.joined(separator: " and "))"
    }
}

extension DeckSummary {
    /// Message for the delete confirmation; states how many cards go with the deck.
    static func deleteConfirmation(cardCount: Int) -> String {
        switch cardCount {
        case 0: "This deck has no cards. This can't be undone."
        case 1: "The 1 card in it will be removed too. This can't be undone."
        default: "All \(cardCount) cards in it will be removed too. This can't be undone."
        }
    }
}

enum DeckSelection {
    /// The deck above (`step` -1) or below (`step` 1) the selected one, for arrow-key navigation. It
    /// stops at the ends rather than wrapping. With nothing selected, down picks the first deck and up
    /// the last.
    static func neighbor(of id: Deck.ID?, in decks: [Deck], step: Int) -> Deck.ID? {
        guard !decks.isEmpty else { return nil }
        let current = decks.firstIndex { $0.id == id } ?? (step > 0 ? -1 : decks.count)
        return decks[min(max(current + step, 0), decks.count - 1)].id
    }

    /// The deck to show: the selected one if it still exists, otherwise the first deck. Widgets
    /// and the notch use the same rule, so deleting a deck they show falls back to the first.
    static func resolve(_ selection: Deck.ID?, in decks: [Deck]) -> Deck? {
        decks.first { $0.id == selection } ?? decks.first
    }
}

enum PasteSummary {
    /// "12 cards found, 2 lines skipped"
    static func text(found: Int, skipped: Int) -> String {
        let foundText: String
        switch found {
        case 0: foundText = "No cards found"
        case 1: foundText = "1 card found"
        default: foundText = "\(found) cards found"
        }
        guard skipped > 0 else { return foundText }
        return "\(foundText), \(skipped) \(skipped == 1 ? "line" : "lines") skipped"
    }
}

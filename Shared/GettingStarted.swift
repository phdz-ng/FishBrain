import Foundation

/// The deck a new user finds on first launch: it explains the app with its own cards, so it also
/// shows up in the widget and the notch straight away.
enum GettingStarted {
    static let deckName = "Getting Started"

    /// A fresh deck each call (new ids), so it can be added again from the Help menu.
    static func deck() -> Deck {
        Deck(name: deckName, color: .accent, cards: cards.map { Card(front: $0.front, back: $0.back) })
    }

    static let cards: [(front: String, back: String)] = [
        (
            "Click a card to flip it",
            "Click a card in the notch or on a widget to see the answer. Click again to turn it back."
        ),
        (
            "How often do cards change?",
            "Every 5 minutes the widget and the notch move to the next card on their own. Skip moves on right away."
        ),
        (
            "Choose a deck for each widget",
            "Right-click a widget, choose Edit Widget, and pick a deck. The notch uses the deck chosen at the bottom of the sidebar."
        ),
        (
            "Add many cards at once",
            "Paste Cards takes a list, one card per line, front and back separated by a comma or a tab. Import CSV reads a .csv, .tsv or .txt file."
        ),
        (
            "Where is the widget?",
            "Right-click the desktop, choose Edit Widgets, search for FishBrain and add a size."
        ),
        (
            "Hover the notch",
            "On a Mac with a notch, move the pointer to it to open the card. Turn it off with Show in notch in the sidebar."
        ),
        (
            "Make it yours",
            "Click a deck's title to rename it, click its icon to change the color, or delete this deck when you're done with it."
        ),
    ]
}

/// What happens the first time the app runs.
@MainActor
enum FirstLaunch {
    /// Adds the "Getting Started" deck to an empty library, once. Someone who already has decks
    /// (an existing user updating) doesn't get one, and a deck that was deleted never comes back.
    static func run(decks: DeckStore, settings: SettingsStore) {
        guard !settings.gettingStartedHandled else { return }
        if decks.decks.isEmpty {
            decks.add(GettingStarted.deck())
        }
        settings.gettingStartedHandled = true
    }
}

/// The text of the welcome sheet.
enum Welcome {
    struct Step: Equatable {
        var title: String
        var detail: String
    }

    /// How to add the widget, how to use the notch, and (when there is one) where to start.
    static func steps(hasGettingStartedDeck: Bool) -> [Step] {
        var steps = [
            Step(
                title: "Add the widget",
                detail: "Right-click an empty spot on the desktop, choose Edit Widgets, search for FishBrain and add a size. Right-click the widget and choose Edit Widget to pick its deck."
            ),
            Step(
                title: "Try the notch",
                detail: "On a Mac with a notch, move the pointer to it to open the card. Turn it off any time with Show in notch in the sidebar."
            ),
        ]
        if hasGettingStartedDeck {
            steps.append(Step(
                title: "Start with the Getting Started deck",
                detail: "Its cards explain the rest, and they are already showing in your widget and notch."
            ))
        }
        return steps
    }
}

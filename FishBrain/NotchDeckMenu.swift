import SwiftUI

/// One group of the notch deck menu: the decks filed directly under a subject ("Spanish › Grammar"),
/// or the loose decks last. With no subjects at all there is one untitled group.
struct NotchDeckMenuSection: Equatable {
    var title: String?
    var decks: [DeckChoice]
}

/// Which deck the notch shows, as a menu: the same in the sidebar footer and in the open notch.
enum NotchDeckMenuModel {
    static let accessibilityLabel = "Notch deck"
    static let hint = "Choose which deck the notch shows"
    /// While a notch study session runs, the open notch's deck is fixed until it ends.
    static let lockedHint = "End the session to switch decks"

    /// The decks grouped under their subjects, loose decks last (`DeckPicker.sections`). Empty decks are
    /// listed too.
    static func sections(decks: [Deck], subjects: [Subject]) -> [NotchDeckMenuSection] {
        DeckPicker.sections(decks: decks, subjects: subjects).map { section in
            NotchDeckMenuSection(title: section.title, decks: section.decks.map { DeckChoice(id: $0.id, name: $0.name) })
        }
    }

    /// The sidebar footer's label. While a session runs on another deck, the choice only takes effect
    /// once it ends: "After this session: Everyday Spanish".
    static func footerLabel(chosen: Deck?, sessionDeckID: Deck.ID?) -> String {
        guard let chosen else { return "No decks" }
        if let sessionDeckID, sessionDeckID != chosen.id { return "After this session: \(chosen.name)" }
        return chosen.name
    }
}

/// The menu's items: a section per subject, a checkmark on the current deck.
struct NotchDeckMenu: View {
    var sections: [NotchDeckMenuSection]
    var currentID: Deck.ID?
    var onChoose: (Deck.ID) -> Void

    var body: some View {
        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
            if let title = section.title {
                Section(title) { buttons(section.decks) }
            } else {
                buttons(section.decks)
            }
        }
    }

    @ViewBuilder
    private func buttons(_ decks: [DeckChoice]) -> some View {
        ForEach(decks) { deck in
            Button {
                onChoose(deck.id)
            } label: {
                if deck.id == currentID {
                    Label(deck.name, systemImage: "checkmark")
                } else {
                    Text(deck.name)
                }
            }
        }
    }
}

import Foundation

struct CardSearchResult: Identifiable, Equatable, Sendable {
    var deckID: Deck.ID
    var deckName: String
    var deckColor: DeckColor
    var card: Card
    /// Where the deck is, "Spanish › Grammar › Verbs", when it is filed under a subject; nil for a loose
    /// deck, which is just `deckName`.
    var deckPath: String?

    var id: Card.ID { card.id }
}

enum CardSearch {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Cards whose front or back (or a picture's description) contains `query`, ignoring case, accents and width. The query is
    /// taken literally (no wildcards). Results keep deck order, then card order. A blank query
    /// matches nothing, which is how the UI tells "not searching" apart from "no matches".
    static func search(_ query: String, in decks: [Deck], subjects: [Subject] = []) -> [CardSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        return decks.flatMap { deck in
            let path = deck.subjectID == nil ? nil : SubjectPath.text(for: deck, in: subjects)
            return deck.cards
                .filter {
                    matches($0.front, needle) || matches($0.back, needle)
                        || matches($0.frontImage?.altText ?? "", needle) || matches($0.backImage?.altText ?? "", needle)
                }
                .map { CardSearchResult(deckID: deck.id, deckName: deck.name, deckColor: deck.color, card: $0, deckPath: path) }
        }
    }

    private static func matches(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: options) != nil
    }
}

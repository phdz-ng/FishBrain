import XCTest

final class CardSearchTests: XCTestCase {
    private let spanish = Deck(name: "Spanish", color: .orange, cards: [
        Card(front: "el señor", back: "the gentleman"),
        Card(front: "la sobremesa", back: "lingering at the table"),
        Card(front: "el café", back: "coffee"),
    ])
    private let french = Deck(name: "French", color: .purple, cards: [
        Card(front: "le café", back: "the coffee shop"),
        Card(front: "la table", back: "the table"),
    ])
    private let empty = Deck(name: "Empty")

    private var decks: [Deck] { [spanish, empty, french] }

    private func fronts(_ query: String, in decks: [Deck]? = nil) -> [String] {
        CardSearch.search(query, in: decks ?? self.decks).map(\.card.front)
    }

    func testMatchesFrontAndBack() {
        XCTAssertEqual(fronts("sobre"), ["la sobremesa"], "front")
        XCTAssertEqual(fronts("gentleman"), ["el señor"], "back")
    }

    func testIsCaseInsensitive() {
        XCTAssertEqual(fronts("SOBREMESA"), ["la sobremesa"])
        XCTAssertEqual(fronts("The Gentleman"), ["el señor"])
    }

    func testIsAccentInsensitiveInBothDirections() {
        XCTAssertEqual(fronts("cafe"), ["el café", "le café"], "plain query finds accented text")
        XCTAssertEqual(fronts("CAFÉ"), ["el café", "le café"], "accented query finds accented text")
        XCTAssertEqual(fronts("senor"), ["el señor"])
        XCTAssertEqual(fronts("señor"), ["el señor"])

        let plain = [Deck(name: "P", cards: [Card(front: "cafe", back: "coffee")])]
        XCTAssertEqual(fronts("café", in: plain), ["cafe"], "accented query finds plain text")
    }

    func testSearchesAcrossAllDecksAndReportsTheOwningDeck() throws {
        let results = CardSearch.search("table", in: decks)
        XCTAssertEqual(results.map(\.card.front), ["la sobremesa", "la table"])
        XCTAssertEqual(results.map(\.deckName), ["Spanish", "French"])
        XCTAssertEqual(results.map(\.deckColor), [.orange, .purple])
        XCTAssertEqual(results[1].deckID, french.id)
        XCTAssertEqual(results[1].id, french.cards[1].id, "results are identified by their card")
    }

    func testResultsKeepDeckThenCardOrder() {
        XCTAssertEqual(fronts("e"), ["el señor", "la sobremesa", "el café", "le café", "la table"])
    }

    func testQueryIsTrimmedAndBlankMatchesNothing() {
        XCTAssertEqual(fronts("  sobre \n"), ["la sobremesa"])
        XCTAssertEqual(fronts(""), [])
        XCTAssertEqual(fronts("   "), [])
    }

    func testQueryIsLiteralNotAPattern() {
        let special = [Deck(name: "S", cards: [Card(front: "a.b", back: "x"), Card(front: "axb", back: "y"), Card(front: "1+1", back: "2")])]
        XCTAssertEqual(fronts("a.b", in: special), ["a.b"])
        XCTAssertEqual(fronts("1+1", in: special), ["1+1"])
        XCTAssertEqual(fronts(".*", in: special), [])
    }

    func testNoMatchesAndEmptyDecks() {
        XCTAssertEqual(fronts("zzz"), [])
        XCTAssertEqual(CardSearch.search("a", in: [empty]), [])
        XCTAssertEqual(CardSearch.search("a", in: []), [])
    }

    func testResultsReflectEdits() {
        var edited = spanish
        XCTAssertEqual(fronts("coffee", in: [edited]), ["el café"])
        edited.cards[2].back = "tea"
        XCTAssertEqual(fronts("coffee", in: [edited]), [])
        XCTAssertEqual(fronts("tea", in: [edited]), ["el café"])
    }

    func testMatchesCardsWithEmptyFrontByTheirBack() {
        let d = [Deck(name: "D", cards: [Card(front: "", back: "only a back")])]
        XCTAssertEqual(CardSearch.search("only", in: d).count, 1)
    }
}

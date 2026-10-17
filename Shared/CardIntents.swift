import AppIntents
import Foundation
import WidgetKit

/// Tapping the card in a widget: toggles front and back for that deck.
struct FlipCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Flip Card"
    static let description = IntentDescription("Shows the other side of the card a widget is showing.")
    /// Only for widget buttons; not offered in Shortcuts.
    static let isDiscoverable = false

    @Parameter(title: "Deck")
    var deckID: String

    init() {}

    init(deckID: Deck.ID) {
        self.deckID = deckID.uuidString
    }

    func perform() async throws -> some IntentResult {
        try PlaybackActions.perform(.flip, deckID: deckID)
        // Refresh every widget on this deck (and any others), not just the one that was tapped.
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// The skip button in a widget: moves that deck to the next card, front side up.
struct SkipCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Card"
    static let description = IntentDescription("Skips to the next card in the deck a widget is showing.")
    static let isDiscoverable = false

    @Parameter(title: "Deck")
    var deckID: String

    init() {}

    init(deckID: Deck.ID) {
        self.deckID = deckID.uuidString
    }

    func perform() async throws -> some IntentResult {
        try PlaybackActions.perform(.skip, deckID: deckID)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// A grade button in a widget (medium and large): rates the card on show and moves to the next one.
struct GradeCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Grade Card"
    static let description = IntentDescription("Says how well you knew the card a widget is showing, and moves to the next one.")
    static let isDiscoverable = false

    @Parameter(title: "Deck")
    var deckID: String

    @Parameter(title: "Grade")
    var grade: String

    init() {}

    init(deckID: Deck.ID, grade: ReviewGrade) {
        self.deckID = deckID.uuidString
        self.grade = grade.rawValue
    }

    func perform() async throws -> some IntentResult {
        if let grade = ReviewGrade(rawValue: grade) {
            try PlaybackActions.perform(.grade(grade), deckID: deckID)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

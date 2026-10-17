import AppIntents
import Foundation

/// A deck as the widget's Edit sheet lists it.
struct DeckEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Deck"
    static let defaultQuery = DeckEntityQuery()

    var id: UUID
    var name: String
    /// The subjects the deck is filed under, "Spanish › Grammar", which tells decks with the same name
    /// apart; nil for a loose deck. The widget itself still shows the deck's name only.
    var subjectPath: String?

    var displayRepresentation: DisplayRepresentation {
        if let subjectPath {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(subjectPath)")
        }
        return DisplayRepresentation(title: "\(name)")
    }

    init(id: UUID, name: String, subjectPath: String? = nil) {
        self.id = id
        self.name = name
        self.subjectPath = subjectPath
    }

    init(_ deck: Deck, subjects: [Subject] = []) {
        self.init(id: deck.id, name: deck.name, subjectPath: SubjectPath.text(of: deck.subjectID, in: subjects))
    }

    /// All decks in library order.
    static func all(in decks: [Deck], subjects: [Subject] = []) -> [DeckEntity] {
        decks.map { DeckEntity($0, subjects: subjects) }
    }

    /// The listed decks that still exist; ids of deleted decks are dropped. A configuration stores the
    /// deck's id, so it keeps working however decks are renamed or filed.
    static func matching(_ ids: [UUID], in decks: [Deck], subjects: [Subject] = []) -> [DeckEntity] {
        decks.filter { ids.contains($0.id) }.map { DeckEntity($0, subjects: subjects) }
    }
}

/// Reads the library fresh each time, so decks created, renamed or deleted in the app show up in
/// the picker without any refresh step.
struct DeckEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [DeckEntity] {
        let library = DeckStorage.shared().loadLibrary()
        return DeckEntity.matching(identifiers, in: library.decks, subjects: library.subjects)
    }

    func suggestedEntities() async throws -> [DeckEntity] {
        let library = DeckStorage.shared().loadLibrary()
        return DeckEntity.all(in: library.decks, subjects: library.subjects)
    }
}

/// Right-click the widget, then Edit Widget: pick which deck this widget instance shows. Leaving
/// it empty (or choosing a deck that is later deleted) falls back to the first deck.
struct SelectDeckIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Deck"
    static let description = IntentDescription("Pick the deck this widget shows.")

    @Parameter(title: "Deck")
    var deck: DeckEntity?
}

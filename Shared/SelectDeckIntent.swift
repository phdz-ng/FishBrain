import AppIntents
import Foundation

/// The deck widget's WidgetKit kind. The app reads placed widgets of this kind to show which deck each
/// one plays (`WidgetDeckCountStore`), which is why the intent lives in Shared.
enum DeckWidgetKind {
    static let kind = "FishBrainWidget"
}

/// A deck as the widget's Edit sheet lists it.
struct DeckEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Deck"
    static let defaultQuery = DeckEntityQuery()

    var id: UUID
    var name: String
    /// The subjects the deck is filed under, "Spanish › Grammar", which tells decks with the same name
    /// apart; nil for a loose deck. The widget itself still shows the deck's name only.
    var subjectPath: String?
    /// The widget was set to this deck, and it has since been deleted (see `DeckEntityQuery`).
    var isDeleted = false

    static let deletedName = "Deleted deck"

    var displayRepresentation: DisplayRepresentation {
        if isDeleted { return DisplayRepresentation(title: "\(Self.deletedName)") }
        if let subjectPath {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(subjectPath)")
        }
        return DisplayRepresentation(title: "\(name)")
    }

    init(id: UUID, name: String, subjectPath: String? = nil, isDeleted: Bool = false) {
        self.id = id
        self.name = name
        self.subjectPath = subjectPath
        self.isDeleted = isDeleted
    }

    /// Stands in for a chosen deck that no longer exists, so the widget still gets its id.
    static func deleted(_ id: UUID) -> DeckEntity {
        DeckEntity(id: id, name: deletedName, isDeleted: true)
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

    /// Every listed id, in order: the deck when it exists, otherwise a deleted stand-in (`deleted(_:)`).
    static func resolving(_ ids: [UUID], in decks: [Deck], subjects: [Subject] = []) -> [DeckEntity] {
        ids.map { id in decks.first { $0.id == id }.map { DeckEntity($0, subjects: subjects) } ?? .deleted(id) }
    }
}

/// Reads the library fresh each time, so decks created, renamed or deleted in the app show up in
/// the picker without any refresh step.
struct DeckEntityQuery: EntityQuery {
    /// WidgetKit asks for the stored deck id of each placed widget here. A dropped id would reach the
    /// timeline as a nil deck, the same as a widget nobody set up, so a deleted deck comes back as a
    /// stand-in that keeps its id: the widget then says the deck was deleted, and Edit Widget shows
    /// "Deleted deck" until another is chosen.
    func entities(for identifiers: [UUID]) async throws -> [DeckEntity] {
        let library = DeckStorage.shared().loadLibrary()
        return DeckEntity.resolving(identifiers, in: library.decks, subjects: library.subjects)
    }

    func suggestedEntities() async throws -> [DeckEntity] {
        let library = DeckStorage.shared().loadLibrary()
        return DeckEntity.all(in: library.decks, subjects: library.subjects)
    }
}

/// Right-click the widget, then Edit Widget: pick which deck this widget instance shows. Leaving it
/// empty shows the first deck; a chosen deck that is later deleted shows "This deck was deleted".
struct SelectDeckIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Deck"
    static let description = IntentDescription("Pick the deck this widget shows.")

    @Parameter(title: "Deck")
    var deck: DeckEntity?
}

import AppIntents
import Foundation

// The widget's deck choice lives in its own framework, linked by both the app and the widget. App
// Intents names a type by its module, so when both targets compiled these files themselves there were
// two DeckEntity types: the Edit Widget sheet saved one, the widget could not read it, and the widget
// ignored the chosen deck. One module means one type.

/// Lets the app and the widget (each an `AppIntentsPackage` that includes this one) see the intents here.
public struct FishBrainIntentsPackage: AppIntentsPackage {}

/// The deck widget's WidgetKit kind. The app reads placed widgets of this kind to show which deck each
/// one plays (`WidgetDeckCountStore`).
public enum DeckWidgetKind {
    public static let kind = "FishBrainWidget"
}

/// Where the framework gets the decks from. The framework knows nothing about the library file; the
/// app and the widget each call `install` when they start, so a query run in either process finds it.
public enum DeckLibrarySource {
    nonisolated(unsafe) public static var decks: @Sendable () -> [DeckEntity] = { [] }

    public static func install(_ decks: @escaping @Sendable () -> [DeckEntity]) {
        self.decks = decks
    }
}

/// A deck as the widget's Edit sheet lists it.
public struct DeckEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Deck"
    public static let defaultQuery = DeckEntityQuery()

    public var id: UUID
    public var name: String
    /// The subjects the deck is filed under, "Spanish › Grammar", which tells decks with the same name
    /// apart; nil for a loose deck. The widget itself still shows the deck's name only.
    public var subjectPath: String?
    /// The widget was set to this deck, and it has since been deleted (see `DeckEntityQuery`).
    public var isDeleted = false

    public static let deletedName = "Deleted deck"

    public var displayRepresentation: DisplayRepresentation {
        if isDeleted { return DisplayRepresentation(title: "\(Self.deletedName)") }
        if let subjectPath {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(subjectPath)")
        }
        return DisplayRepresentation(title: "\(name)")
    }

    public init(id: UUID, name: String, subjectPath: String? = nil, isDeleted: Bool = false) {
        self.id = id
        self.name = name
        self.subjectPath = subjectPath
        self.isDeleted = isDeleted
    }

    /// Stands in for a chosen deck that no longer exists, so the widget still gets its id.
    public static func deleted(_ id: UUID) -> DeckEntity {
        DeckEntity(id: id, name: deletedName, isDeleted: true)
    }

    /// Every listed id, in order: the deck when it exists, otherwise a deleted stand-in (`deleted(_:)`).
    public static func resolving(_ ids: [UUID], in decks: [DeckEntity]) -> [DeckEntity] {
        ids.map { id in decks.first { $0.id == id } ?? .deleted(id) }
    }
}

/// Reads the library fresh each time, so decks created, renamed or deleted in the app show up in
/// the picker without any refresh step.
public struct DeckEntityQuery: EntityQuery {
    public init() {}

    /// WidgetKit asks for the stored deck id of each placed widget here. A dropped id would reach the
    /// timeline as a nil deck, the same as a widget nobody set up, so a deleted deck comes back as a
    /// stand-in that keeps its id: the widget then says the deck was deleted, and Edit Widget shows
    /// "Deleted deck" until another is chosen.
    public func entities(for identifiers: [UUID]) async throws -> [DeckEntity] {
        DeckEntity.resolving(identifiers, in: DeckLibrarySource.decks())
    }

    public func suggestedEntities() async throws -> [DeckEntity] {
        DeckLibrarySource.decks()
    }
}

/// Right-click the widget, then Edit Widget: pick which deck this widget instance shows. Leaving it
/// empty shows the first deck; a chosen deck that is later deleted shows "This deck was deleted".
public struct SelectDeckIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Choose Deck"
    public static let description = IntentDescription("Pick the deck this widget shows.")

    @Parameter(title: "Deck")
    public var deck: DeckEntity?

    public init() {}
}

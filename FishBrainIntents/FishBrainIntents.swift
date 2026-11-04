import AppIntents
import Foundation

// The widget's deck choice lives in its own library, linked by both the app and the widget. App
// Intents names a type by its module, so when both targets compiled these files themselves there were
// two SelectDeckIntent types: the Edit Widget sheet saved one, the widget could not read it, and the
// widget ignored the chosen deck. One module means one type.

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

/// A deck as the widget's Edit sheet lists it. Not an `AppEntity`: the widget stores the deck's id as a
/// plain string (see `SelectDeckIntent`). An entity parameter is resolved by the system's `linkd`
/// service, which refuses a widget without a Team ID, so on an unsigned build the chosen deck never
/// reached the widget and it showed the first deck whatever you picked.
public struct DeckEntity: Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// The subjects the deck is filed under, "Spanish › Grammar", which tells decks with the same name
    /// apart; nil for a loose deck. The widget itself still shows the deck's name only.
    public var subjectPath: String?
    /// The widget was set to this deck, and it has since been deleted.
    public var isDeleted = false

    public static let deletedName = "Deleted deck"

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

/// Lists the decks in the Edit Widget picker, by name, with the deck's id as the stored value. Reads
/// the library fresh each time, so decks created, renamed or deleted in the app show up without any
/// refresh step.
public struct DeckOptionsProvider: DynamicOptionsProvider {
    public init() {}

    public func results() async throws -> IntentItemCollection<String> {
        let items: [IntentItem<String>] = DeckLibrarySource.decks().map { deck in
            if let path = deck.subjectPath {
                return IntentItem(deck.id.uuidString, title: "\(deck.name)", subtitle: "\(path)")
            }
            return IntentItem(deck.id.uuidString, title: "\(deck.name)")
        }
        return IntentItemCollection(sections: [IntentItemSection(items: items)])
    }
}

/// Right-click the widget, then Edit Widget: pick which deck this widget instance shows. Leaving it
/// empty shows the first deck; a chosen deck that is later deleted shows "This deck was deleted".
public struct SelectDeckIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Choose Deck"
    public static let description = IntentDescription("Pick the deck this widget shows.")

    /// The chosen deck's id (a UUID string).
    @Parameter(title: "Deck", optionsProvider: DeckOptionsProvider())
    public var deckID: String?

    public init() {}

    /// The chosen deck's id; nil when none is chosen.
    public var deck: UUID? { deckID.flatMap(UUID.init(uuidString:)) }
}

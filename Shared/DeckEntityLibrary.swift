import FishBrainIntents
import Foundation

// The part of the widget's deck choice that needs the library. The types themselves are in the
// FishBrainIntents framework (see there for why).

extension DeckEntity {
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

    /// Every listed id, in order: the deck when it exists, otherwise a deleted stand-in.
    static func resolving(_ ids: [UUID], in decks: [Deck], subjects: [Subject] = []) -> [DeckEntity] {
        resolving(ids, in: all(in: decks, subjects: subjects))
    }
}

/// Tells the framework where the decks are. Call once when the app or the widget starts.
enum DeckEntitySource {
    static func install() {
        DeckLibrarySource.install {
            let library = DeckStorage.shared().loadLibrary()
            return DeckEntity.all(in: library.decks, subjects: library.subjects)
        }
    }
}

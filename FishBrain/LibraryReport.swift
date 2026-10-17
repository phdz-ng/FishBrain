import Foundation

#if DEBUG
/// A plain-text summary of the shared library, for troubleshooting what the widget can see.
enum LibraryReport {
    static func print() {
        let container = AppGroup.containerURL
        let directory = AppGroup.storageDirectory()
        Swift.print("App Group id:        \(AppGroup.identifier)")
        Swift.print("Group container:     \(container?.path ?? "UNAVAILABLE (falling back to Application Support)")")
        Swift.print("Reading from:        \(directory.path)")
        for name in [DeckStorage.fileName, PlaybackStorage.fileName, SettingsStorage.fileName] {
            let url = directory.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            Swift.print("  \(name): \(size.map { "\($0) bytes" } ?? "missing")")
        }
        let decks = DeckStorage.shared().load()
        Swift.print("Decks: \(decks.count)")
        for (index, deck) in decks.enumerated() {
            Swift.print("  \(index + 1). \"\(deck.name)\"  \(deck.cards.count) cards")
        }
        let first = DeckSelection.resolve(nil, in: decks)
        Swift.print("Widget default deck (first): \(first.map { "\"\($0.name)\", \($0.cards.count) cards" } ?? "none")")
    }
}
#endif

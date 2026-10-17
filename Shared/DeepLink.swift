import Foundation

/// `fishbrain://` links: how widgets (and anything else) ask the app to open on a deck.
enum DeepLink {
    static let scheme = "fishbrain"

    /// Just open the app.
    static var app: URL { URL(string: "\(scheme)://open")! }

    static func deck(_ id: Deck.ID) -> URL {
        URL(string: "\(scheme)://deck/\(id.uuidString)")!
    }

    /// The deck a link points at, or nil for any other link.
    static func deckID(from url: URL) -> Deck.ID? {
        guard url.scheme == scheme, url.host == "deck" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

/// The kinds of file the Import sheet reads, so double-clicking one, dropping one on the window and the
/// file chooser all agree.
enum ImportFile {
    static let extensions: Set<String> = ["csv", "tsv", "txt", "apkg"]

    static func isImportable(_ url: URL) -> Bool {
        url.isFileURL && extensions.contains(url.pathExtension.lowercased())
    }
}

/// Hands links from the system to the main window, whether the app was already running, closed
/// its window, or was launched by the link itself.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    /// A deck the window should switch to; the window clears it once it has.
    @Published var pendingDeckID: Deck.ID?
    /// A CSV or Anki package the system opened with FishBrain (double-click, Open With, AirDrop); the
    /// window shows the Import sheet on it and clears this.
    @Published var pendingImportURL: URL?

    /// Returns whether the link was one of ours.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        if url.isFileURL {
            guard ImportFile.isImportable(url) else { return false }
            pendingImportURL = url
            return true
        }
        guard url.scheme == DeepLink.scheme else { return false }
        if let id = DeepLink.deckID(from: url) {
            pendingDeckID = id
        }
        return true
    }
}

import SwiftUI

/// Connects menu commands to the main window. The window registers what each command should do
/// while it is open; a command with nothing registered is greyed out.
@MainActor
final class CommandCenter: ObservableObject {
    static let shared = CommandCenter()

    @Published var newDeck: (() -> Void)?
    @Published var newSubject: (() -> Void)?
    /// nil when there is no deck to add a card to.
    @Published var addCard: (() -> Void)?
    @Published var focusSearch: (() -> Void)?
    /// Opens the Export sheet on what is open; nil with no window.
    @Published var exportSelection: (() -> Void)?
    /// Opens the Import sheet; nil with no window.
    @Published var importFile: (() -> Void)?
    @Published var createWithAI: (() -> Void)?
    @Published var showWelcome: (() -> Void)?
    @Published var addGettingStarted: (() -> Void)?
    /// Puts the picture on the clipboard on the card side being edited; nil when none is.
    @Published var pastePicture: (() -> Void)?

    func clear() {
        newDeck = nil
        newSubject = nil
        addCard = nil
        focusSearch = nil
        exportSelection = nil
        importFile = nil
        createWithAI = nil
        showWelcome = nil
        addGettingStarted = nil
        pastePicture = nil
    }
}

struct AppCommands: Commands {
    @ObservedObject private var center = CommandCenter.shared
    @ObservedObject var settings: SettingsStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Deck") { center.newDeck?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(center.newDeck == nil)
            Button("New Subject") { center.newSubject?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(center.newSubject == nil)
            Button("Add Card") { center.addCard?() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(center.addCard == nil)
            Button("Create with AI") { center.createWithAI?() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(center.createWithAI == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("Import…") { center.importFile?() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(center.importFile == nil)
            Button("Export…") { center.exportSelection?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(center.exportSelection == nil)
        }
        // Plain Paste is greyed out while a text field is being edited and the clipboard holds only a
        // picture, so pictures get a command of their own.
        CommandGroup(after: .pasteboard) {
            Button("Paste Picture") { center.pastePicture?() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(center.pastePicture == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to FishBrain") { center.showWelcome?() }
                .disabled(center.showWelcome == nil)
            Button("Add Getting Started Deck") { center.addGettingStarted?() }
                .disabled(center.addGettingStarted == nil)
        }
        // View ▸ Appearance ▸ Light / Dark / Match system, so it can be changed from the keyboard.
        CommandGroup(after: .toolbar) {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearanceMenuItems.items(selected: settings.appearance), id: \.choice) { item in
                    Text(item.title).tag(item.choice)
                }
            }
        }
        CommandGroup(after: .textEditing) {
            Button("Find Cards") { center.focusSearch?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(center.focusSearch == nil)
        }
    }
}

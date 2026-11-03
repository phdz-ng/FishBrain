import AppKit
import SwiftUI

@main
struct FishBrainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The same instances the notch uses (see `AppEnvironment`).
    @StateObject private var store = AppEnvironment.shared.deckStore
    @StateObject private var settings = AppEnvironment.shared.settingsStore
    @StateObject private var playback = AppEnvironment.shared.playbackStore

    init() {
        // Before the first window, so it opens in the chosen appearance.
        AppearanceController.shared.start(settings: AppEnvironment.shared.settingsStore)
    }

    var body: some Scene {
        Window("FishBrain", id: "main") {
            MainWindowView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(playback)
                .environmentObject(AppEnvironment.shared.studyStore)
                .environmentObject(AppEnvironment.shared.runHistoryStore)
                .environmentObject(AppEnvironment.shared.studyClockGate)
                .environmentObject(AppEnvironment.shared.aiStore)
                .environmentObject(AppEnvironment.shared.composer)
                .environment(\.accentChoice, settings.accent)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.flush()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 680)
        .commands { AppCommands(settings: settings) }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(AppEnvironment.shared.aiStore)
                .environment(\.accentChoice, settings.accent)
        }
    }
}

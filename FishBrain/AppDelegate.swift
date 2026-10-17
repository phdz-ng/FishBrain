import AppKit

/// Keeps the app running after the window is closed (the notch lives on) and lets the Dock
/// icon bring the window back.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // `-FishBrainPrintLibrary` prints what the app (and so the widget) sees in the shared
        // folder, then quits. Handy because only the app itself may read that folder.
        if ProcessInfo.processInfo.arguments.contains("-FishBrainPrintLibrary") {
            _ = AppEnvironment.shared // runs the migration, as a normal launch would
            LibraryReport.print()
            exit(0)
        }
        if ProcessInfo.processInfo.arguments.contains("-FishBrainPrintAccessibility") {
            AccessibilityReport.run()
        }
        if ProcessInfo.processInfo.arguments.contains("-FishBrainShowSettings") {
            // Opens Settings on the AI tab, for looking at it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                SettingsNavigator.shared.tab = .ai
                NSApp.activate(ignoringOtherApps: true)
                // The app menu's own Settings item, which is what a click would use.
                if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title.hasPrefix("Settings") }), let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-FishBrainPrintNotch") {
            NotchReport.print()
            exit(0)
        }
        #endif
        NotchDisplayManager.shared.start()
        CopyToCardService.shared.start()
    }

    /// Cards from Create with AI that haven't been saved are lost on quitting, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let count = MainActor.assumeIsolated { AppEnvironment.shared.composer.draft?.cards.count ?? 0 }
        guard MainActor.assumeIsolated({ AppEnvironment.shared.composer.hasUnsavedDraft }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Discard the cards you haven't saved?"
        alert.informativeText = count > 0
            ? "Create with AI has \(count) \(count == 1 ? "card" : "cards") that \(count == 1 ? "isn't" : "aren't") in a deck yet. If you quit now they are lost."
            : "Create with AI is still making cards. If you quit now they are lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit and Discard")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// `fishbrain://deck/<id>` from a widget: switch to that deck and bring the window back, even
    /// if it was closed.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { DeepLinkRouter.shared.handle(url) }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.styleMask.contains(.titled) }?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}

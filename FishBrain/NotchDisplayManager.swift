import AppKit
import Combine

/// Runs one notch per display that should have one. Which displays those are comes from
/// `NotchDisplayPolicy`; this class only watches for the things that change the answer (displays
/// coming and going, a Space or app switch, a full-screen app, the settings) and starts or hides
/// a `NotchController` to match. Nothing polls.
@MainActor
final class NotchDisplayManager: ObservableObject {
    static let shared = NotchDisplayManager()

    private(set) var controllers: [UInt32: NotchController] = [:]
    /// The displays that may show a notch right now; each controller asks this before showing.
    private(set) var allowed: Set<UInt32> = []
    /// Whether a notch FishBrain draws itself is on screen right now (Settings says so next to the
    /// pill style, which only applies to those).
    @Published private(set) var hasDrawnNotch = false

    private let screensProvider: @MainActor () -> [ScreenMetrics]
    private let activeDisplayProvider: @MainActor ([ScreenMetrics]) -> UInt32?
    private let settingsProvider: @MainActor () -> SettingsStore
    private let makeController: @MainActor (_ displayID: UInt32, _ gate: @escaping @MainActor () -> Bool) -> NotchController
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var subscriptions: [AnyCancellable] = []
    private var pendingRecheck: Task<Void, Never>?

    init(
        screens: @escaping @MainActor () -> [ScreenMetrics] = { NSScreen.screens.map(ScreenMetrics.init) },
        activeDisplay: @escaping @MainActor ([ScreenMetrics]) -> UInt32? = { NotchDisplayManager.activeDisplayID(in: $0) },
        settings: @escaping @MainActor () -> SettingsStore = { AppEnvironment.shared.settingsStore },
        makeController: @escaping @MainActor (_ displayID: UInt32, _ gate: @escaping @MainActor () -> Bool) -> NotchController = { id, gate in
            NotchController(
                placementProvider: { NotchController.placement(forDisplayID: id) },
                visibilityGate: gate,
                studyStore: { AppEnvironment.shared.studyStore },
                sessionStore: { AppEnvironment.shared.sessionStore },
                studyClock: { AppEnvironment.shared.studyClockGate },
                copyStore: { AppEnvironment.shared.copyOfferStore }
            )
        }
    ) {
        self.screensProvider = screens
        self.activeDisplayProvider = activeDisplay
        self.settingsProvider = settings
        self.makeController = makeController
    }

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        // Displays plugged in or removed, resolution changes, the menu bar appearing or hiding.
        observe(.default, NSApplication.didChangeScreenParametersNotification)
        // Another Space or a full-screen app coming forward, or the focused app moving to another display.
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification, recheckAgain: true)
        observe(workspace, NSWorkspace.didActivateApplicationNotification)
        settingsProvider().objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &subscriptions)
        reconcile()
    }

    func stop() {
        observers.forEach { $0.center.removeObserver($0.token) }
        observers = []
        subscriptions = []
        pendingRecheck?.cancel()
        pendingRecheck = nil
        controllers.values.forEach { $0.stop() }
        controllers = [:]
        allowed = []
    }

    /// Works out which displays should show a notch and brings the controllers in line.
    func reconcile() {
        let screens = screensProvider()
        allowed = NotchDisplayPolicy.displaysToShow(
            screens: screens,
            activeDisplayID: activeDisplayProvider(screens),
            options: settingsProvider().displayOptions
        )

        let attached = Set(screens.map(\.displayID))
        for id in controllers.keys where !attached.contains(id) {
            controllers[id]?.stop()
            controllers[id] = nil
        }
        for id in allowed where controllers[id] == nil {
            let controller = makeController(id) { [weak self] in self?.allowed.contains(id) ?? false }
            controllers[id] = controller
            controller.start()
        }
        // Shows or hides the rest, and puts each panel back where its display now is.
        controllers.values.forEach { $0.refreshContent() }
        let drawn = controllers.values.contains { $0.isShowing && !$0.model.hasCamera }
        if hasDrawnNotch != drawn { hasDrawnNotch = drawn }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, recheckAgain: Bool = false) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcile()
                if recheckAgain { self?.recheckSoon() }
            }
        }
        observers.append((center, token))
    }

    /// A full-screen app hides the menu bar partway through its animation, after the notification
    /// has fired, so look again once things have settled.
    private func recheckSoon() {
        pendingRecheck?.cancel()
        pendingRecheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    /// Opens the card editor on `front`, on the display the pointer is on (or the first one with a notch).
    func openCardEditor(front: String) {
        let pointer = NSEvent.mouseLocation
        let screenID = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }?.displayID
        let controller = screenID.flatMap { controllers[$0] } ?? controllers.values.first { $0.isShowing }
        controller?.beginCardDraft(front: front)
    }

    /// The display the focused app's front window is on, which is the one whose menu bar is active.
    /// Reading window bounds and owners needs no permission.
    static func activeDisplayID(in screens: [ScreenMetrics]) -> UInt32? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for window in windows {
                guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                      (window[kCGWindowLayer as String] as? Int) == 0,
                      let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
                if let id = ActiveDisplay.displayID(forWindowBounds: bounds, screens: screens) { return id }
            }
        }
        return NSScreen.main?.displayID
    }
}

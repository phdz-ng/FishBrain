import AppKit
import Carbon.HIToolbox
import Combine

/// What the service needs from the clipboard, so tests can supply their own.
@MainActor
protocol PasteboardSource {
    var changeCount: Int { get }
    var typeIdentifiers: [String] { get }
    /// False when macOS would ask the user before this app may read what was copied.
    var canReadWithoutPrompt: Bool { get }
    func string() -> String?
}

@MainActor
struct SystemPasteboard: PasteboardSource {
    private var pasteboard: NSPasteboard { .general }

    var changeCount: Int { pasteboard.changeCount }
    var typeIdentifiers: [String] { (pasteboard.types ?? []).map(\.rawValue) }

    /// Recent macOS versions alert (or refuse) when an app reads the clipboard without the user pasting,
    /// unless the user has set the app to Always Allow in System Settings > Privacy & Security > Paste
    /// from Other Apps. Only then is the text read in the background; otherwise it waits for a click.
    var canReadWithoutPrompt: Bool {
        if #available(macOS 15.4, *) { return pasteboard.accessBehavior == .alwaysAllow }
        return true
    }

    func string() -> String? { pasteboard.string(forType: .string) }
}

@MainActor
protocol HotKeyRegistering: AnyObject {
    @discardableResult func register(_ handler: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

/// A system-wide shortcut, Control-Option-C. It uses the Carbon hot key API, which needs no
/// permission (a global key monitor would need Accessibility access).
@MainActor
final class GlobalHotKey: HotKeyRegistering {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    fileprivate var action: (@MainActor () -> Void)?

    @discardableResult
    func register(_ handler: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        action = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let key = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // Delivered on the main thread by the application event target.
            MainActor.assumeIsolated { key.action?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard installed == noErr else { return false }
        let id = EventHotKeyID(signature: OSType(0x4642_5243), id: 1) // 'FBRC'
        return RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        action = nil
    }
}

/// Offers a card for what you copy. While "Offer to make a card when I copy text" is on, it looks at the
/// clipboard once a second (macOS has no notification for a copy) and, for a copy of a word or short
/// phrase made in another app, puts an offer in the notch. It also registers Control-Option-C, which opens
/// the card editor on whatever is on the clipboard. Off, nothing runs and nothing is read.
@MainActor
final class CopyToCardService {
    static let shared = CopyToCardService()

    /// A once-a-second look at one number. The timer is allowed to drift by half a second, so the Mac can
    /// batch it with other wake-ups.
    static let pollInterval: TimeInterval = 1
    static let pollTolerance: TimeInterval = 0.5

    private let pasteboard: PasteboardSource
    private let storeProvider: @MainActor () -> CopyOfferStore
    private let settingsProvider: @MainActor () -> SettingsStore
    private let clock: () -> Date
    private let isOwnAppActive: @MainActor () -> Bool
    private let openEditor: @MainActor (String) -> Void
    private let hotKey: HotKeyRegistering

    private var tracker = CopyOfferTracker()
    private var lastSeenChangeCount = 0
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private(set) var isRunning = false

    init(
        pasteboard: PasteboardSource? = nil,
        store: @escaping @MainActor () -> CopyOfferStore = { AppEnvironment.shared.copyOfferStore },
        settings: @escaping @MainActor () -> SettingsStore = { AppEnvironment.shared.settingsStore },
        clock: @escaping () -> Date = Date.init,
        isOwnAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        openEditor: @escaping @MainActor (String) -> Void = { NotchDisplayManager.shared.openCardEditor(front: $0) },
        hotKey: HotKeyRegistering? = nil
    ) {
        self.pasteboard = pasteboard ?? SystemPasteboard()
        self.storeProvider = store
        self.settingsProvider = settings
        self.clock = clock
        self.isOwnAppActive = isOwnAppActive
        self.openEditor = openEditor
        self.hotKey = hotKey ?? GlobalHotKey()
    }

    /// Follows the setting: runs while it is on.
    func start() {
        guard subscription == nil else { return }
        let settings = settingsProvider()
        apply(enabled: settings.offersCardFromCopy)
        subscription = settings.$offersCardFromCopy
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { self?.apply(enabled: enabled) }
            }
    }

    func stop() {
        subscription = nil
        apply(enabled: false)
    }

    func apply(enabled: Bool) {
        guard enabled != isRunning else { return }
        isRunning = enabled
        if enabled {
            // What is on the clipboard now was copied before the setting was turned on.
            lastSeenChangeCount = pasteboard.changeCount
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = Self.pollTolerance
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            hotKey.register { [weak self] in self?.openEditorOnClipboard() }
        } else {
            timer?.invalidate()
            timer = nil
            hotKey.unregister()
            storeProvider().dismiss()
        }
    }

    /// One look at the clipboard. Public so tests can drive it without a timer.
    func tick() {
        guard isRunning else { return }
        let count = pasteboard.changeCount
        guard count != lastSeenChangeCount else { return }
        lastSeenChangeCount = count
        // A copy made inside FishBrain isn't one to offer a card for.
        guard !isOwnAppActive() else { return }
        let types = pasteboard.typeIdentifiers
        guard CopyCandidate.hasText(typeIdentifiers: types), !CopyCandidate.isConcealed(typeIdentifiers: types) else { return }

        let now = clock()
        if pasteboard.canReadWithoutPrompt {
            guard let text = CopyCandidate.text(from: pasteboard.string()), tracker.shouldOffer(text, at: now) else { return }
            storeProvider().offer(text: text, at: now)
        } else {
            // Without reading it: any text copy gets an offer, with no way to tell a word from a
            // paragraph. The text is read when the offer is clicked.
            storeProvider().offer(text: nil, at: now)
        }
    }

    /// Control-Option-C: the editor, on what is on the clipboard now. Reading it here is the user's own
    /// doing, so it is fine whatever the clipboard permission says.
    func openEditorOnClipboard() {
        openEditor(CopyCandidate.prefill(from: pasteboard.string()))
    }
}

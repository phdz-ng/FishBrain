import Foundation
import OSLog
import WidgetKit

/// App-side observable settings. Changing a value saves immediately. Widgets show the accent, so
/// only an accent change asks WidgetKit to rebuild them; the notch observes this store directly.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var accent: AccentChoice {
        didSet { if accent != oldValue { save(reloadsWidgets: true) } }
    }
    /// Light, Dark or Match system. The widget follows it too.
    @Published var appearance: AppearanceChoice {
        didSet { if appearance != oldValue { save(reloadsWidgets: true) } }
    }
    /// "Show in notch".
    @Published var showsNotch: Bool {
        didSet { if showsNotch != oldValue { save(reloadsWidgets: false) } }
    }
    /// The deck the notch studies; nil means the first deck.
    @Published var notchDeckID: Deck.ID? {
        didSet { if notchDeckID != oldValue { save(reloadsWidgets: false) } }
    }
    @Published var gettingStartedHandled: Bool {
        didSet { if gettingStartedHandled != oldValue { save(reloadsWidgets: false) } }
    }
    @Published var hasSeenWelcome: Bool {
        didSet { if hasSeenWelcome != oldValue { save(reloadsWidgets: false) } }
    }
    /// "Show on external displays".
    @Published var showsOnExternalDisplays: Bool {
        didSet { if showsOnExternalDisplays != oldValue { save(reloadsWidgets: false) } }
    }
    /// "Hide when an app is full screen".
    @Published var hidesInFullScreen: Bool {
        didSet { if hidesInFullScreen != oldValue { save(reloadsWidgets: false) } }
    }
    /// "Only on the display with the active menu bar".
    @Published var onlyOnActiveDisplay: Bool {
        didSet { if onlyOnActiveDisplay != oldValue { save(reloadsWidgets: false) } }
    }
    /// "What the pill shows" on a drawn notch.
    @Published var pillStyle: PillStyle {
        didSet { if pillStyle != oldValue { save(reloadsWidgets: false) } }
    }
    /// "Flip every" for the Card notch.
    @Published var notchFlipInterval: NotchFlipInterval {
        didSet { if notchFlipInterval != oldValue { save(reloadsWidgets: false) } }
    }
    /// Cards to study each day for the streak.
    @Published var dailyGoal: Int {
        didSet {
            if dailyGoal < 1 { dailyGoal = max(oldValue, 1) }
            if dailyGoal != oldValue { save(reloadsWidgets: false) }
        }
    }
    /// "Grade with the keyboard".
    @Published var keyboardGrading: Bool {
        didSet { if keyboardGrading != oldValue { save(reloadsWidgets: false) } }
    }
    /// "Offer to make a card when I copy text".
    @Published var offersCardFromCopy: Bool {
        didSet { if offersCardFromCopy != oldValue { save(reloadsWidgets: false) } }
    }
    /// Create with AI: provider, models and the defaults for a run.
    @Published var ai: AISettings {
        didSet { if ai != oldValue { save(reloadsWidgets: false) } }
    }
    /// How long the last Review sprint was set for.
    @Published var reviewMinutes: Int {
        didSet {
            let clamped = ReviewRun.clamped(minutes: reviewMinutes)
            if clamped != reviewMinutes { reviewMinutes = clamped }
            if reviewMinutes != oldValue { save(reloadsWidgets: false) }
        }
    }
    @Published private(set) var lastSaveError: Error?

    private let storage: SettingsStorage
    private let onSaved: @MainActor () -> Void
    private let logger = Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "settings")

    init(
        storage: SettingsStorage = .shared(),
        onSaved: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.storage = storage
        self.onSaved = onSaved
        // Two one-time migrations, each with its own flag: light themes, then Classic to Card.
        let (migrated, migratedLightTheme) = LightThemeMigration.apply(storage.load())
        var loaded = migrated
        let migratedPillStyle = loaded.migratePillStyleToCard()
        self.accent = loaded.accent
        self.appearance = loaded.appearance
        self.showsNotch = loaded.showsNotch
        self.notchDeckID = loaded.notchDeckID
        self.gettingStartedHandled = loaded.gettingStartedHandled
        self.hasSeenWelcome = loaded.hasSeenWelcome
        self.showsOnExternalDisplays = loaded.showsOnExternalDisplays
        self.hidesInFullScreen = loaded.hidesInFullScreen
        self.onlyOnActiveDisplay = loaded.onlyOnActiveDisplay
        self.pillStyle = loaded.pillStyle
        self.notchFlipInterval = loaded.notchFlipInterval
        self.dailyGoal = loaded.dailyGoal
        self.keyboardGrading = loaded.keyboardGrading
        self.offersCardFromCopy = loaded.offersCardFromCopy
        self.ai = loaded.ai
        self.reviewMinutes = loaded.reviewMinutes
        // The light theme changes what the widget draws; the pill style does not.
        if migratedLightTheme || migratedPillStyle { save(reloadsWidgets: migratedLightTheme) }
    }

    /// What decides which displays get a notch.
    var displayOptions: NotchDisplayOptions {
        NotchDisplayOptions(
            showsNotch: showsNotch, showsOnExternalDisplays: showsOnExternalDisplays,
            hidesInFullScreen: hidesInFullScreen, onlyOnActiveDisplay: onlyOnActiveDisplay
        )
    }

    private func save(reloadsWidgets: Bool) {
        do {
            var settings = AppSettings(
                accent: accent, showsNotch: showsNotch, notchDeckID: notchDeckID,
                gettingStartedHandled: gettingStartedHandled, hasSeenWelcome: hasSeenWelcome,
                showsOnExternalDisplays: showsOnExternalDisplays, hidesInFullScreen: hidesInFullScreen,
                onlyOnActiveDisplay: onlyOnActiveDisplay, pillStyle: pillStyle,
                // The Card migration always ran in init, so a save records it as done.
                notchFlipInterval: notchFlipInterval, didMigratePillStyleCard1: true,
                dailyGoal: dailyGoal, keyboardGrading: keyboardGrading,
                offersCardFromCopy: offersCardFromCopy, ai: ai, reviewMinutes: reviewMinutes
            )
            settings.appearance = appearance
            try storage.save(settings)
            lastSaveError = nil
            if reloadsWidgets { onSaved() }
        } catch {
            lastSaveError = error
            logger.error("Save failed: \(error.localizedDescription)")
        }
    }
}

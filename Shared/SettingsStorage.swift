import Foundation
import OSLog

/// User preferences shared by the app, widget and notch.
struct AppSettings: Codable, Equatable, Sendable {
    var accent: AccentChoice = .default
    /// "Show in notch". On by default.
    var showsNotch = true
    /// The deck the notch studies; nil means the first deck.
    var notchDeckID: UUID?
    /// First launch has already decided about the "Getting Started" deck, so it is never added again
    /// (even if the user deletes it).
    var gettingStartedHandled = false
    /// The welcome sheet has been shown once.
    var hasSeenWelcome = false
    /// "Show on external displays": a drawn notch on monitors other than the Mac's own display.
    var showsOnExternalDisplays = false
    /// "Hide when an app is full screen" (or the menu bar is hidden). On by default.
    var hidesInFullScreen = true
    /// "Only on the display with the active menu bar".
    var onlyOnActiveDisplay = false
    /// What the notch shows at rest.
    var pillStyle: PillStyle = .default
    /// "Flip every": how often the resting Card notch turns between front and answer.
    var notchFlipInterval: NotchFlipInterval = .default
    /// The Classic-to-Card move has run (`migratePillStyleToCard`). A new install never needs it; a
    /// file written before it existed decodes as false.
    var didMigratePillStyleCard1 = true
    /// Cards to study each day for the streak.
    var dailyGoal = AppSettings.defaultDailyGoal
    /// "Grade with the keyboard": keys 1 to 4 in the open notch. Off by default, because it means the
    /// notch takes the keyboard from the app in front while a card is turned over.
    var keyboardGrading = false
    /// "Offer to make a card when I copy text". Off by default: it looks at what you copy.
    var offersCardFromCopy = false
    /// Create with AI: which provider and model, and the defaults for a run.
    var ai = AISettings()
    /// How long the last Review sprint was set for, which the next one starts with.
    var reviewMinutes = ReviewRun.defaultMinutes
    static let defaultDailyGoal = 20
    static let dailyGoalChoices = [10, 20, 30, 50]

    init(
        accent: AccentChoice = .default,
        showsNotch: Bool = true,
        notchDeckID: UUID? = nil,
        gettingStartedHandled: Bool = false,
        hasSeenWelcome: Bool = false,
        showsOnExternalDisplays: Bool = false,
        hidesInFullScreen: Bool = true,
        onlyOnActiveDisplay: Bool = false,
        pillStyle: PillStyle = .default,
        notchFlipInterval: NotchFlipInterval = .default,
        didMigratePillStyleCard1: Bool = true,
        dailyGoal: Int = AppSettings.defaultDailyGoal,
        keyboardGrading: Bool = false,
        offersCardFromCopy: Bool = false,
        ai: AISettings = AISettings(),
        reviewMinutes: Int = ReviewRun.defaultMinutes
    ) {
        self.accent = accent
        self.showsNotch = showsNotch
        self.notchDeckID = notchDeckID
        self.gettingStartedHandled = gettingStartedHandled
        self.hasSeenWelcome = hasSeenWelcome
        self.showsOnExternalDisplays = showsOnExternalDisplays
        self.hidesInFullScreen = hidesInFullScreen
        self.onlyOnActiveDisplay = onlyOnActiveDisplay
        self.pillStyle = pillStyle
        self.notchFlipInterval = notchFlipInterval
        self.didMigratePillStyleCard1 = didMigratePillStyleCard1
        self.dailyGoal = max(dailyGoal, 1)
        self.keyboardGrading = keyboardGrading
        self.offersCardFromCopy = offersCardFromCopy
        self.ai = ai
        self.reviewMinutes = ReviewRun.clamped(minutes: reviewMinutes)
    }

    /// Missing keys fall back to defaults so older files keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accent = try container.decodeIfPresent(AccentChoice.self, forKey: .accent) ?? .default
        showsNotch = try container.decodeIfPresent(Bool.self, forKey: .showsNotch) ?? true
        notchDeckID = try container.decodeIfPresent(UUID.self, forKey: .notchDeckID)
        gettingStartedHandled = try container.decodeIfPresent(Bool.self, forKey: .gettingStartedHandled) ?? false
        hasSeenWelcome = try container.decodeIfPresent(Bool.self, forKey: .hasSeenWelcome) ?? false
        showsOnExternalDisplays = try container.decodeIfPresent(Bool.self, forKey: .showsOnExternalDisplays) ?? false
        hidesInFullScreen = try container.decodeIfPresent(Bool.self, forKey: .hidesInFullScreen) ?? true
        onlyOnActiveDisplay = try container.decodeIfPresent(Bool.self, forKey: .onlyOnActiveDisplay) ?? false
        // A file without a style was written when Classic was the only one; the migration moves it on.
        pillStyle = try container.decodeIfPresent(PillStyle.self, forKey: .pillStyle) ?? .classic
        notchFlipInterval = try container.decodeIfPresent(NotchFlipInterval.self, forKey: .notchFlipInterval) ?? .default
        didMigratePillStyleCard1 = try container.decodeIfPresent(Bool.self, forKey: .didMigratePillStyleCard1) ?? false
        dailyGoal = max(try container.decodeIfPresent(Int.self, forKey: .dailyGoal) ?? Self.defaultDailyGoal, 1)
        keyboardGrading = try container.decodeIfPresent(Bool.self, forKey: .keyboardGrading) ?? false
        offersCardFromCopy = try container.decodeIfPresent(Bool.self, forKey: .offersCardFromCopy) ?? false
        ai = try container.decodeIfPresent(AISettings.self, forKey: .ai) ?? AISettings()
        reviewMinutes = ReviewRun.clamped(
            minutes: try container.decodeIfPresent(Int.self, forKey: .reviewMinutes) ?? ReviewRun.defaultMinutes
        )
    }
}

/// Reads and writes `settings.json` next to `decks.json` in the App Group container. The widget
/// reads it each time it builds a timeline; the app writes it.
struct SettingsStorage: Sendable {
    static let fileName = "settings.json"
    private static let logger = Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "settings")

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) {
        self.directory = directory
    }

    static func shared() -> SettingsStorage {
        SettingsStorage(directory: AppGroup.storageDirectory())
    }

    /// Never throws: a missing or unreadable file yields the defaults.
    func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            Self.logger.error("Unreadable \(Self.fileName), using defaults: \(error.localizedDescription)")
            return AppSettings()
        }
    }

    /// Atomic: the widget sees either the old or the new file, never a partial one.
    func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}

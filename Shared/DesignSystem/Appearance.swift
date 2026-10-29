import SwiftUI

/// Light, Dark or Match system. Stored in the shared settings so the app and the widget agree.
enum AppearanceChoice: String, Codable, CaseIterable, Sendable {
    // The order of the menu items and the Settings tiles.
    case light, dark, system

    static let `default` = AppearanceChoice.light

    /// Unknown values (e.g. written by a newer version) decode as the default.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AppearanceChoice(rawValue: raw) ?? .default
    }

    var displayName: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "Match system"
        }
    }

    /// The scheme to force, or nil to follow the Mac.
    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    /// The appearance in use when the Mac is in `system`.
    func resolved(system: ColorScheme) -> ColorScheme {
        colorScheme ?? system
    }

    /// The toolbar button's icon: what is showing right now, a sun or a moon.
    static func iconName(for scheme: ColorScheme) -> String {
        scheme == .dark ? "moon.fill" : "sun.max.fill"
    }

    /// What VoiceOver reads as the button's value: "Light", "Dark" or "Match system, now light".
    func accessibilityValue(system: ColorScheme) -> String {
        switch self {
        case .light, .dark: displayName
        case .system: "Match system, now \(system == .dark ? "dark" : "light")"
        }
    }
}

/// Light themes, once: the first launch of the version that has them moves everyone to Light, and
/// moves Indigo (the old default, which nearly everyone has saved) to Orange. Blue, Purple and Teal
/// were picked on purpose and are kept. Recorded in `AppSettings.didMigrateLightTheme1`, so it never
/// runs again and never undoes a later choice.
enum LightThemeMigration {
    static func apply(_ settings: AppSettings) -> (settings: AppSettings, didChange: Bool) {
        guard !settings.didMigrateLightTheme1 else { return (settings, false) }
        var migrated = settings
        migrated.appearance = .light
        if migrated.accent == .indigo { migrated.accent = .orange }
        migrated.didMigrateLightTheme1 = true
        return (migrated, true)
    }
}

import AppIntents
import SwiftUI
import WidgetKit

struct FishBrainProvider: AppIntentTimelineProvider {
    /// Shown while the widget loads; WidgetKit redacts the text into the usual placeholder blocks.
    func placeholder(in context: Context) -> FishBrainEntry {
        FishBrainEntry.sample
    }

    func snapshot(for configuration: SelectDeckIntent, in context: Context) async -> FishBrainEntry {
        // The gallery's picker should always show a realistic card, even for an empty library.
        if context.isPreview {
            let settings = LightThemeMigration.apply(SettingsStorage.shared().load()).settings
            return FishBrainEntry.gallery(accent: settings.accent, appearance: settings.appearance)
        }
        return FishBrainEntry.current(deckID: configuration.deck?.id)
    }

    /// An entry for now and one per 5-minute slot for the next hour, then a fresh timeline. The app
    /// reloads timelines after deck edits, flips and skips.
    func timeline(for configuration: SelectDeckIntent, in context: Context) async -> Timeline<FishBrainEntry> {
        let result = FishBrainEntry.currentTimeline(deckID: configuration.deck?.id)
        return Timeline(entries: result.entries, policy: .after(result.reloadDate))
    }
}

struct FishBrainWidget: Widget {
    let kind = "FishBrainWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectDeckIntent.self, provider: FishBrainProvider()) { entry in
            FishBrainWidgetView(entry: entry)
        }
        .configurationDisplayName("FishBrain")
        .description("Flip through your flashcards. Edit the widget to choose a deck.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

#if DEBUG
#Preview("Small", as: .systemSmall) {
    FishBrainWidget()
} timeline: {
    FishBrainEntry.sample()
    FishBrainEntry.sample(flipped: true)
    FishBrainEntry.sample(longText: true)
}

#Preview("Medium", as: .systemMedium) {
    FishBrainWidget()
} timeline: {
    FishBrainEntry.sample()
    FishBrainEntry.sample(flipped: true, accent: .teal)
    FishBrainEntry.sample(appearance: .dark)
    FishBrainEntry.sample(flipped: true, appearance: .dark)
    FishBrainEntry.sample(longText: true)
}

#Preview("Empty states", as: .systemMedium) {
    FishBrainWidget()
} timeline: {
    FishBrainEntry.make(decks: [], playback: [:], accent: .indigo, at: Date())
    FishBrainEntry.make(decks: [Deck(name: "Everyday Spanish")], playback: [:], accent: .indigo, at: Date())
}

#Preview("Large", as: .systemLarge) {
    FishBrainWidget()
} timeline: {
    FishBrainEntry.sample()
    FishBrainEntry.sample(flipped: true, longText: true)
}
#endif

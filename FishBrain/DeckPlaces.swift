import FishBrainIntents
import SwiftUI
import WidgetKit

/// Where a deck is playing: in the notch, and on how many desktop widgets. Shown as badges on its
/// sidebar row.
struct DeckPlaces: Equatable {
    var inNotch = false
    var widgets = 0

    static let none = DeckPlaces()

    var isEmpty: Bool { !inNotch && widgets == 0 }

    /// "In the notch", "In 1 widget", "In 2 widgets", "In the notch and 2 widgets"; nil when nowhere.
    var tooltip: String? {
        phrase.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    /// The same words for VoiceOver, after the deck's name and card count: "in the notch and 2 widgets".
    var phrase: String? {
        var parts: [String] = []
        if inNotch { parts.append("the notch") }
        if widgets > 0 { parts.append(widgets == 1 ? "1 widget" : "\(widgets) widgets") }
        guard !parts.isEmpty else { return nil }
        return "in " + parts.joined(separator: " and ")
    }

    /// How many placed widgets show each deck. `chosen` is each widget's configured deck id: nil when
    /// nobody set it up (the widget shows the first deck, as `DeckSelection.resolve` says), or an id
    /// that may since have been deleted (that widget says so and counts for nothing). With `chosen`
    /// nil the widgets' settings couldn't be read, and nothing is counted, never a wrong number.
    static func widgetCounts(chosen: [Deck.ID?]?, decks: [Deck]) -> [Deck.ID: Int] {
        guard let chosen else { return [:] }
        let known = Set(decks.map(\.id))
        var counts: [Deck.ID: Int] = [:]
        for id in chosen {
            let shown: Deck.ID?
            if let id { shown = known.contains(id) ? id : nil } else { shown = decks.first?.id }
            if let shown { counts[shown, default: 0] += 1 }
        }
        return counts
    }

    /// Every deck's places. The notch's deck counts only while Show in notch is on; during a notch study
    /// session that is the session's deck.
    static func all(
        decks: [Deck], chosenByWidgets: [Deck.ID?]?, showsNotch: Bool, notchDeckID: Deck.ID?, sessionDeckID: Deck.ID?
    ) -> [Deck.ID: DeckPlaces] {
        let counts = widgetCounts(chosen: chosenByWidgets, decks: decks)
        let notchDeck = showsNotch ? (sessionDeckID ?? DeckSelection.resolve(notchDeckID, in: decks)?.id) : nil
        var places: [Deck.ID: DeckPlaces] = [:]
        for deck in decks {
            let entry = DeckPlaces(inNotch: deck.id == notchDeck, widgets: counts[deck.id] ?? 0)
            if !entry.isEmpty { places[deck.id] = entry }
        }
        return places
    }
}

extension SettingsStore {
    /// Whether the notch shows this deck right now: it is the notch's deck and Show in notch is on.
    func isShowingInNotch(_ id: Deck.ID, decks: [Deck]) -> Bool {
        showsNotch && DeckSelection.resolve(notchDeckID, in: decks)?.id == id
    }

    /// A deck's "Show in Notch": the notch shows it, and Show in notch is turned on.
    func showInNotch(_ id: Deck.ID) {
        notchDeckID = id
        showsNotch = true
    }
}

/// What the placed FishBrain widgets are set to, read from WidgetKit when the main window becomes
/// active and after the library changes. macOS doesn't tell the app when a widget is edited, so the
/// counts can be briefly stale until then.
@MainActor
final class WidgetDeckCountStore: ObservableObject {
    /// Each placed widget's chosen deck id (nil for one nobody set up); nil when they couldn't be read.
    @Published private(set) var chosen: [Deck.ID?]?

    private let load: @MainActor () async throws -> [Deck.ID?]?
    private var refreshing: Task<Void, Never>?

    init(load: @escaping @MainActor () async throws -> [Deck.ID?]? = WidgetDeckCountStore.readWidgetCenter) {
        self.load = load
    }

    func refresh() {
        refreshing?.cancel()
        refreshing = Task { [weak self, load] in
            let result: [Deck.ID?]?
            do { result = try await load() } catch { result = nil }
            guard !Task.isCancelled, let self else { return }
            if self.chosen != result { self.chosen = result }
        }
    }

    /// Waits for the refresh in flight; for tests.
    func settle() async { await refreshing?.value }

    /// The deck each placed FishBrain widget is set to. Any widget whose settings can't be decoded makes
    /// the whole answer unknown (nil), so the sidebar shows no widget badges rather than a wrong count.
    static func readWidgetCenter() async throws -> [Deck.ID?]? {
        // The async `currentConfigurations()` needs macOS 15; this one works from 14.
        let all = try await withCheckedThrowingContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { continuation.resume(with: $0) }
        }
        let widgets = all.filter { $0.kind == DeckWidgetKind.kind }
        var chosen: [Deck.ID?] = []
        for widget in widgets {
            guard let intent = widget.widgetConfigurationIntent(of: SelectDeckIntent.self) else { return nil }
            chosen.append(intent.deck?.id)
        }
        return chosen
    }
}

/// The small glyphs after a deck's name in the sidebar: a notch glyph, and a widget glyph with a count
/// when two or more widgets show the deck.
struct DeckPlacesBadges: View {
    var places: DeckPlaces
    var isSelected = false

    var body: some View {
        HStack(spacing: 5) {
            if places.inNotch {
                Image(systemName: "menubar.rectangle")
            }
            if places.widgets > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "rectangle.on.rectangle")
                    if places.widgets > 1 { Text("\(places.widgets)").monospacedDigit() }
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(isSelected ? Theme.TextColor.onAccent : Theme.TextColor.secondary)
        .help(places.tooltip ?? "")
        .accessibilityHidden(true) // the row's label says it
    }
}

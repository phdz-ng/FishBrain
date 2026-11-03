import AppIntents
import OSLog
import SwiftUI
import WidgetKit

/// What the widget shows at one point in time.
struct FishBrainEntry: TimelineEntry {
    var date: Date
    var accent: AccentChoice
    /// Light, Dark or Match system, from the app's settings.
    var appearance: AppearanceChoice = .default
    /// nil when there is no deck, or the deck has no cards (see `emptyState`).
    var showing: NowShowing?
    /// Why there is nothing to show; nil when `showing` is set.
    var emptyState: WidgetEmptyState?
    var nextRotation: Date

    /// Where a tap outside the buttons goes: the deck on show, or just the app.
    var openURL: URL {
        if let showing { return DeepLink.deck(showing.deckID) }
        if case .emptyDeck(let id, _) = emptyState { return DeepLink.deck(id) }
        return DeepLink.app
    }

    /// Shows the chosen deck, or the first deck when none was chosen or the chosen one was deleted.
    static func make(
        decks: [Deck],
        playback: [Deck.ID: PlaybackState],
        accent: AccentChoice,
        appearance: AppearanceChoice = .default,
        at date: Date,
        deckID: Deck.ID? = nil,
        scheduler: CardScheduler = CardScheduler()
    ) -> FishBrainEntry {
        let deck = DeckSelection.resolve(deckID, in: decks)
        let showing = deck.flatMap {
            NowShowing.make(deck: $0, state: playback[$0.id] ?? PlaybackState(), at: date, scheduler: scheduler)
        }
        var emptyState: WidgetEmptyState?
        if showing == nil {
            emptyState = deck.map { .emptyDeck(id: $0.id, name: $0.name) } ?? .noDecks
        }
        return FishBrainEntry(
            date: date,
            accent: accent,
            appearance: appearance,
            showing: showing,
            emptyState: emptyState,
            nextRotation: scheduler.nextRotation(after: date)
        )
    }

    private static let logger = Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "widget")

    /// Reads the shared files, and logs what was found (visible with `log show`, no `--info` needed)
    /// so a widget that looks empty can be told apart from one that can't read the library.
    private static func loadShared() -> (decks: [Deck], playback: [Deck.ID: PlaybackState], accent: AccentChoice, appearance: AppearanceChoice) {
        let directory = AppGroup.storageDirectory()
        let decks = DeckStorage.shared().load()
        let cards = decks.reduce(0) { $0 + $1.cards.count }
        logger.notice("Widget read \(decks.count) decks, \(cards) cards from \(directory.path, privacy: .public)")
        // Until the app has run once after the update, show what its migration will choose.
        let settings = LightThemeMigration.apply(SettingsStorage.shared().load()).settings
        return (decks, PlaybackStorage.shared().load(), settings.accent, settings.appearance)
    }

    /// Reads the shared App Group files.
    static func current(at date: Date = Date(), deckID: Deck.ID? = nil) -> FishBrainEntry {
        let shared = loadShared()
        return make(decks: shared.decks, playback: shared.playback, accent: shared.accent, appearance: shared.appearance, at: date, deckID: deckID)
    }

    /// An entry for now plus one for every 5-minute slot boundary within `horizon`, each showing
    /// what the scheduler picks at that moment. WidgetKit swaps entries on its own as their dates
    /// arrive, and an entry whose date has already passed (after sleep, say) is applied on the next
    /// render, so the right card shows without anything having to wake up on time.
    static func timeline(
        decks: [Deck],
        playback: [Deck.ID: PlaybackState],
        accent: AccentChoice,
        appearance: AppearanceChoice = .default,
        at now: Date,
        deckID: Deck.ID? = nil,
        horizon: TimeInterval = 3600,
        scheduler: CardScheduler = CardScheduler()
    ) -> EntryTimeline {
        func entry(at date: Date) -> FishBrainEntry {
            make(decks: decks, playback: playback, accent: accent, appearance: appearance, at: date, deckID: deckID, scheduler: scheduler)
        }

        let first = entry(at: now)
        guard first.showing != nil else {
            // Nothing to rotate; edits in the app reload the widget, this is just a safety net.
            return EntryTimeline(entries: [first], reloadDate: now.addingTimeInterval(horizon))
        }

        var entries = [first]
        var boundary = scheduler.nextRotation(after: now)
        while boundary <= now.addingTimeInterval(horizon) {
            entries.append(entry(at: boundary))
            boundary = boundary.addingTimeInterval(scheduler.interval)
        }
        // Ask for a fresh timeline when the last prepared card's slot ends.
        return EntryTimeline(entries: entries, reloadDate: entries.last?.nextRotation ?? boundary)
    }

    /// Timeline for the widget, from the shared App Group files.
    static func currentTimeline(at now: Date = Date(), deckID: Deck.ID? = nil) -> EntryTimeline {
        let shared = loadShared()
        return timeline(
            decks: shared.decks, playback: shared.playback, accent: shared.accent, appearance: shared.appearance, at: now, deckID: deckID
        )
    }
}

/// Why a widget has no card to show.
enum WidgetEmptyState: Equatable, Sendable {
    case noDecks
    case emptyDeck(id: Deck.ID, name: String)

    var title: String {
        switch self {
        case .noDecks: "Open FishBrain to create your first deck"
        case .emptyDeck(_, let name): "Add cards to “\(name)”"
        }
    }

    var subtitle: String? {
        switch self {
        case .noDecks: nil
        case .emptyDeck: "Open FishBrain to add some."
        }
    }
}

struct EntryTimeline: Equatable {
    var entries: [FishBrainEntry]
    /// When WidgetKit should ask for a fresh timeline.
    var reloadDate: Date
}

extension FishBrainEntry: Equatable {
    static func == (lhs: FishBrainEntry, rhs: FishBrainEntry) -> Bool {
        lhs.date == rhs.date && lhs.accent == rhs.accent && lhs.appearance == rhs.appearance && lhs.showing == rhs.showing
            && lhs.emptyState == rhs.emptyState && lhs.nextRotation == rhs.nextRotation
    }
}

extension FishBrainEntry {
    /// Sample content for the widget gallery and previews.
    static var sample: FishBrainEntry { sample() }

    /// A realistic card, in the user's accent, for the widget gallery's picker; shown instead of
    /// an empty state even when the library is empty.
    static func gallery(accent: AccentChoice, appearance: AppearanceChoice = .default) -> FishBrainEntry {
        sample(accent: accent, appearance: appearance)
    }

    static func sample(
        flipped: Bool = false, accent: AccentChoice = .default, appearance: AppearanceChoice = .default, longText: Bool = false
    ) -> FishBrainEntry {
        let card = longText
            ? Card(
                front: "What is the difference between a process and a thread in an operating system?",
                back: "A process has its own address space and resources; threads share the memory and resources of their process, so they are cheaper to create and switch between."
            )
            : Card(front: "la sobremesa", back: "lingering at the table after a meal")
        let deck = Deck(name: "Everyday Spanish", color: .accent, cards: (0..<48).map { _ in Card(front: card.front, back: card.back) })
        let now = Date()
        var state = PlaybackState()
        if flipped {
            state = CardScheduler().flipping(state, in: deck, at: now)
        }
        return make(decks: [deck], playback: [deck.id: state], accent: accent, appearance: appearance, at: now)
    }
}

/// The widget in small, medium and large, in the app's appearance. Long text scales down instead of
/// clipping, and the countdown ticks on its own without timeline reloads.
struct FishBrainWidgetView: View {
    var entry: FishBrainEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        FishBrainWidgetContent(entry: entry, family: family)
    }
}

/// The widget's layout for an explicit family (the environment's family can't be set in tests).
struct FishBrainWidgetContent: View {
    var entry: FishBrainEntry
    var family: WidgetFamily

    var body: some View {
        Group {
            if let showing = entry.showing {
                switch family {
                case .systemSmall: SmallWidgetContent(showing: showing)
                case .systemLarge: RichWidgetContent(showing: showing, entry: entry, size: .large)
                default: RichWidgetContent(showing: showing, entry: entry, size: .medium)
                }
            } else {
                EmptyWidgetContent(state: entry.emptyState ?? .noDecks, family: family)
            }
        }
        // A tap anywhere that isn't a button opens the app on this widget's deck.
        .widgetURL(entry.openURL)
        .environment(\.accentChoice, entry.accent)
        .containerBackground(for: .widget) {
            ZStack {
                Rectangle().fill(Theme.Blur.window)
                Rectangle().fill(entry.showing?.isFlipped == true ? entry.accent.flippedSurface : Theme.Surface.widget)
            }
        }
        .modifier(WidgetAppearance(choice: entry.appearance))
    }
}

/// Light or Dark from the app's setting, while the widget draws its own colors. Match system leaves the
/// system's choice; so do the tinted and dimmed desktop modes, where macOS picks the colors itself.
struct WidgetAppearance: ViewModifier {
    var choice: AppearanceChoice

    @Environment(\.widgetRenderingMode) private var renderingMode

    func body(content: Content) -> some View {
        if renderingMode == .fullColor, let scheme = choice.colorScheme {
            content.environment(\.colorScheme, scheme)
        } else {
            content
        }
    }
}

private struct SmallWidgetContent: View {
    var showing: NowShowing

    var body: some View {
        VStack(spacing: 0) {
            // Outside the flip button, so tapping the header opens the app on this deck.
            HStack {
                Text(showing.deckName).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 6)
                Text(showing.positionText).monospacedDigit()
            }
            .font(Theme.Typography.micro)
            .foregroundStyle(Theme.TextColor.meta(isFlipped: showing.isFlipped))
            .padding(.horizontal, 14)
            .padding(.top, 14)

            Button(intent: FlipCardIntent(deckID: showing.deckID)) {
                CardFace(
                    text: showing.isFlipped ? showing.card.back : showing.card.front,
                    isBack: showing.isFlipped,
                    size: .small,
                    minimumScaleFactor: 0.4,
                    image: showing.isFlipped ? showing.card.backImage : showing.card.frontImage,
                    useThumbnail: true
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Flips the card")
        }
    }
}

/// Medium and large share a layout; large just has more room for longer answers.
private struct RichWidgetContent: View {
    var showing: NowShowing
    var entry: FishBrainEntry
    var size: CardFace.Size

    @Environment(\.accentChoice) private var accent

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                DeckIcon(color: showing.deckColor, size: 18)
                Text(showing.deckName).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(showing.position) of \(showing.total)").monospacedDigit()
                Button(intent: SkipCardIntent(deckID: showing.deckID)) {
                    SkipGlyph()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next card")
            }
            .font(Theme.Typography.footnote)
            .foregroundStyle(Theme.TextColor.meta(isFlipped: showing.isFlipped))

            Button(intent: FlipCardIntent(deckID: showing.deckID)) {
                CardFace(
                    text: showing.isFlipped ? showing.card.back : showing.card.front,
                    isBack: showing.isFlipped,
                    size: size,
                    minimumScaleFactor: 0.4,
                    image: showing.isFlipped ? showing.card.backImage : showing.card.frontImage,
                    useThumbnail: true
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Flips the card")

            // Once the card is turned over, how well you knew it; otherwise the countdown. The same
            // height either way, so the card doesn't resize when it flips.
            Group {
                if showing.isFlipped {
                    WidgetGradeRow(deckID: showing.deckID, intervals: showing.gradeIntervals)
                } else {
                    HStack(spacing: 8) {
                        // A static bar per entry, not ProgressView(timerInterval:): that live view is laid out
                        // inside NotificationCenter, where it hit "view origin is invalid: (nan, ...)" and
                        // crash-looped it, taking every widget and Edit Widgets down with it. The countdown
                        // text still ticks; the bar is exact at each entry's date, and entries sit on slot boundaries.
                        CountdownProgressBar(progress: slotProgress)
                            .widgetAccentable()
                        HStack(spacing: 3) {
                            Text("Next in")
                            Text(timerInterval: slotStart...entry.nextRotation, countsDown: true, showsHours: false)
                                .monospacedDigit()
                                .multilineTextAlignment(.trailing)
                        }
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.TextColor.meta(isFlipped: showing.isFlipped))
                        // A fixed width, not `.fixedSize()`: the live countdown has no width the extension can
                        // measure while laying the widget out, and an unmeasurable width in this row gave the
                        // bar beside it an infinite width and a NaN origin ("view origin is invalid"), which
                        // crashed the extension on every reload so macOS only ever showed the placeholder.
                        .frame(width: 84, alignment: .trailing)
                    }
                }
            }
            .frame(height: 30)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var slotStart: Date {
        entry.nextRotation.addingTimeInterval(-CardScheduler.defaultInterval)
    }

    /// How far through the 5-minute slot the entry's date is, 0...1.
    private var slotProgress: Double {
        entry.date.timeIntervalSince(slotStart) / CardScheduler.defaultInterval
    }
}

/// Again, Hard, Good and Easy under a turned-over card, each with the gap it would set. Each is a
/// button that runs `GradeCardIntent`, so it works from the desktop without opening the app. Medium and
/// large only: the small widget has no room for them.
private struct WidgetGradeRow: View {
    var deckID: Deck.ID
    var intervals: GradeIntervals

    @Environment(\.accentChoice) private var accent

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ReviewGrade.allCases, id: \.self) { grade in
                Button(intent: GradeCardIntent(deckID: deckID, grade: grade)) {
                    VStack(spacing: 1) {
                        Text(grade.displayName)
                            .font(Theme.Typography.micro.weight(.semibold))
                        Text(intervals.label(grade))
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.6))
                    }
                    .foregroundStyle(Theme.TextColor.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(grade == .good ? accent.fill.with(opacity: 0.45) : Theme.TextColor.primary.with(opacity: 0.11))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(grade.displayName), next in \(intervals.label(grade))")
            }
        }
    }
}

/// The skip control from the design; wrapped in a `Button(intent:)` by the caller.
private struct SkipGlyph: View {
    var body: some View {
        Image(systemName: "forward.fill")
            .font(.system(size: 10))
            .foregroundStyle(Theme.TextColor.primary)
            .frame(width: 28, height: 22)
            .background(Capsule().fill(Theme.Surface.control))
            .accessibilityHidden(true) // the Button around it is labeled "Next card"
    }
}

/// What the widget says when there is nothing to show: no decks yet, or the chosen deck is empty.
private struct EmptyWidgetContent: View {
    var state: WidgetEmptyState
    var family: WidgetFamily

    @Environment(\.accentChoice) private var accent

    private var isSmall: Bool { family == .systemSmall }

    var body: some View {
        VStack(spacing: isSmall ? 8 : 10) {
            StackGlyph()
                .stroke(accent.light, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: isSmall ? 28 : 36, height: isSmall ? 28 : 36)
                .widgetAccentable()
            Text(state.title)
                .font((isSmall ? Theme.Typography.caption : Theme.Typography.body).weight(.semibold))
                .foregroundStyle(Theme.TextColor.primary)
                .minimumScaleFactor(0.7)
            if let subtitle = state.subtitle {
                Text(subtitle)
                    .font(isSmall ? Theme.Typography.micro : Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(isSmall ? 14 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

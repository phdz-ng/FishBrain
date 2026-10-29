import AppKit
import Combine
import SwiftUI

extension ScreenMetrics {
    init(_ screen: NSScreen) {
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea,
            displayID: screen.displayID ?? 0,
            isBuiltIn: screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        )
    }
}

extension NSScreen {
    /// The `CGDirectDisplayID`, which stays the same for a display while the screen list changes.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// The window the notch display lives in: borderless and transparent, above the menu bar, on every
/// Space and over full-screen apps, and it never takes focus from whatever you are working in.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above the menu bar (which is at `.mainMenu`).
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        titleVisibility = .hidden
        // Dark in every app appearance: the notch is black like the hardware, with light text.
        appearance = NSAppearance(named: .darkAqua)
    }

    /// Whether the panel may take the keyboard. Only while grade buttons are on screen, so the keys
    /// 1 to 4 reach them; otherwise it never does, and the active app keeps typing.
    var allowsKeyboard = false

    // Never main, and key only while grading: clicks and hovers reach the panel, but the active app
    // stays active.
    override var canBecomeKey: Bool { allowsKeyboard }
    override var canBecomeMain: Bool { false }

    /// Hands the keyboard back to whatever app was in front. A panel that stays on screen can't just
    /// resign key, so it steps off screen and back, which restores the previous window.
    func releaseKeyboard() {
        allowsKeyboard = false
        guard isKeyWindow else { return }
        orderOut(nil)
        orderFrontRegardless()
    }
}

/// Black with rounded bottom corners, like the notch it extends.
struct NotchShape: Shape {
    var radius: CGFloat = 10

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// A card being written from the open notch (copy to card).
struct CardDraft: Equatable {
    var front: String
    var back = ""
    var deckID: Deck.ID?
}

struct DeckChoice: Equatable, Identifiable {
    var id: Deck.ID
    var name: String
}

/// Where the study session stands, as the notch shows it.
enum SessionPhase: Equatable {
    case idle
    case running(SessionInfo)
    case recap(StudySession.Result)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// The notch's own 30-second session, which has its own rotation (a sprint doesn't).
    var isNotchSession: Bool {
        if case .running(let info) = self { return info.kind == .session }
        return false
    }

    /// A Review sprint is running in the app.
    var isSprint: Bool {
        if case .running(let info) = self { return info.kind == .sprint }
        return false
    }
}

/// A study clock that is running, as the notch draws it: the same for a session and a sprint.
typealias SessionInfo = StudyClockInfo

/// What the notch view shows and how big it is. Set by the controller.
@MainActor
final class NotchModel: ObservableObject {
    @Published var isExpanded = false
    @Published var showing: NowShowing?
    @Published var accent: AccentChoice = .default
    @Published var collapsedSize = CGSize(width: 253, height: 33)
    @Published var expandedSize = NotchGeometry.expandedSize
    /// The gap in the middle of the resting panel, where the camera housing is.
    @Published var notchWidth: CGFloat = 185
    /// False where FishBrain draws the notch itself: nothing sits in the middle, so the content does.
    @Published var hasCamera = true
    /// The chosen style. A drawn notch shows it at rest; a real notch shows Card or Classic.
    @Published var pillStyle: PillStyle = .default
    /// "Flip every" for the Card style.
    @Published var flipInterval: NotchFlipInterval = .default
    /// When the resting card started on its front: a new card arrived or the notch closed. The
    /// resting flip counts from here.
    @Published var restStartedAt = Date()
    /// Where the Card style puts the text on this display.
    @Published var cardLayout: CardRestLayout = .drawn
    /// The deck's color when the deck has no cards, so the Card style can show its icon.
    @Published var emptyDeckColor: DeckColor?
    /// False while the panel isn't on screen (the display sleeps, the screen is locked, it is
    /// covered), so nothing at rest animates then.
    @Published var restIsVisible = true
    /// Today's count, the goal, the streak and this week; nil where nothing tracks studying.
    @Published var study: StudySummary?
    /// The study session: running, just ended (the recap), or nothing.
    @Published var session: SessionPhase = .idle
    /// The last finished session, for "Last: 22 cards".
    @Published var lastSession: StudySession.Result?
    /// The length the Start session button uses.
    @Published var sessionMinutes = StudySession.defaultMinutes
    /// False where nothing keeps sessions (tests, previews): the notch hides the session controls.
    @Published var sessionsAvailable = false
    /// Whether the grade buttons may show: not during a study session, which has its own rotation. A
    /// sprint leaves the notch's rotation alone, so the notch grades as usual.
    var canGrade: Bool { !session.isNotchSession }
    /// How long a card lasts right now: 5 minutes, or 30 seconds in a session.
    @Published var rotationInterval = CardScheduler.defaultInterval
    /// The offer to make a card from what was just copied, or the note that one was made.
    @Published var banner: CopyBanner?
    /// The card being written in the open notch; nil when the study card is showing.
    @Published var cardDraft: CardDraft?
    /// The decks a new card can go in, for the editor's deck menu.
    @Published var deckChoices: [DeckChoice] = []
    /// The camera housing's height (or the menu bar's); expanded content starts below it.
    @Published var notchHeight: CGFloat = 33
    /// When the card next changes; drives the countdown and progress bar.
    @Published var nextRotation = Date()
    /// True while the expanded card is on screen or still animating closed. The once-a-second
    /// countdown only exists while this is true, so a collapsed notch costs nothing.
    @Published var showsExpandedContent = false

    /// What the notch draws at rest. On a drawn notch a session takes the pill over for as long as it
    /// runs and while its recap shows, whatever style is chosen. A real notch shows Card when Card is
    /// chosen, and Classic otherwise.
    var restStyle: PillStyle {
        guard !hasCamera else { return PillStyle.onRealNotch(pillStyle) }
        return session == .idle ? pillStyle : .session
    }

    /// Whatever rests in the notch may animate: it is closed and on screen.
    var restIsActive: Bool { !isExpanded && restIsVisible }

    var onAcceptOffer: () -> Void = {}
    var onSaveDraft: () -> Void = {}
    var onCancelDraft: () -> Void = {}
    var onGrade: (ReviewGrade) -> Void = { _ in }
    var onStartSession: (Int) -> Void = { _ in }
    var onEndSession: () -> Void = {}
    var onSetSessionMinutes: (Int) -> Void = { _ in }
    /// Brings FishBrain forward to the sprint that is running.
    var onGoToSprint: () -> Void = {}
    var onFlip: () -> Void = {}
    var onSkip: () -> Void = {}
    /// Opens or closes the notch without the mouse (VoiceOver, where there is no hovering).
    var onToggleExpanded: () -> Void = {}
}

/// The card turns around a vertical axis; the side that faces you changes at the quarter turn. With
/// Reduce Motion it crossfades instead and nothing rotates.
struct FlipView<Front: View, Back: View>: View, Animatable {
    var angle: Double
    var style: NotchCard.FlipStyle = .rotate
    /// The axis it turns about: vertical for the open card, horizontal for the resting Card notch.
    var axis: (x: CGFloat, y: CGFloat, z: CGFloat) = (x: 0, y: 1, z: 0)
    var front: Front
    var back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let opacities = NotchCard.faceOpacities(angle: angle, style: style)
        switch style {
        case .rotate:
            ZStack {
                front.opacity(opacities.front)
                // Turned the other way round, so the back reads correctly once the card has flipped.
                back.rotation3DEffect(.degrees(180), axis: axis).opacity(opacities.back)
            }
            .rotation3DEffect(.degrees(angle), axis: axis, perspective: 0.5)
        case .crossfade:
            ZStack {
                front.opacity(opacities.front)
                back.opacity(opacities.back)
            }
        }
    }
}

/// A hosting view that accepts the click that also brings the window forward, so the first click
/// on the notch card works even though FishBrain isn't the active app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMouseContainerView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The notch display. At rest it extends the notch with the deck icon on the left of the camera
/// and the position on the right; when expanded it opens with a spring.
struct NotchRootView: View {
    @ObservedObject var model: NotchModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.76)

    var body: some View {
        let size = model.isExpanded ? model.expandedSize : model.collapsedSize
        ZStack(alignment: .top) {
            // The shape springs open; with Reduce Motion it jumps to size and only the content fades.
            NotchShape(radius: model.isExpanded ? 26 : 10)
                .fill(Theme.Surface.notch)
                .frame(width: size.width, height: size.height)
                .animation(reduceMotion ? nil : Self.spring, value: model.isExpanded)

            restingContent
                .frame(width: model.collapsedSize.width, height: model.collapsedSize.height)
                .opacity(model.isExpanded ? 0 : 1)
                .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: model.isExpanded)
                // Only the state on screen is in VoiceOver's reach.
                .accessibilityHidden(model.isExpanded)

            expandedContent
                .frame(width: model.expandedSize.width, height: model.expandedSize.height)
                .opacity(model.isExpanded ? 1 : 0)
                .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: model.isExpanded)
                .accessibilityHidden(!model.isExpanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.accentChoice, model.accent)
        // Always dark, whatever the app's appearance: the notch is black like the hardware.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var restingContent: some View {
        if let banner = model.banner {
            // A copy to offer a card for, or a card just made. The offer is a button: the panel takes
            // clicks for as long as it is showing.
            let content = PillRestContent(
                style: model.restStyle, showing: model.showing ?? .sample, hasCamera: model.hasCamera, notchWidth: model.notchWidth,
                banner: banner
            )
            if banner.isOffer {
                Button(action: model.onAcceptOffer) { content.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(banner.announcement)
                    .accessibilityHint("Opens a new card to fill in")
            } else {
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(banner.announcement)
            }
        } else if let showing = model.showing {
            PillRestContent(
                style: model.restStyle, showing: showing, hasCamera: model.hasCamera, notchWidth: model.notchWidth,
                nextRotation: model.nextRotation, isActive: model.restIsActive, study: model.study,
                session: model.session, lastSession: model.lastSession, rotationInterval: model.rotationInterval,
                cardLayout: model.cardLayout, flipInterval: model.flipInterval, restStartedAt: model.restStartedAt
            )
            // Hovering is the mouse's way in; VoiceOver users get the same through an action.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(restingAccessibilityLabel(showing))
            .accessibilityHint("Opens the study card")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.onToggleExpanded() }
        } else if model.restStyle == .card, let color = model.emptyDeckColor {
            // A deck with no cards yet: its icon, and nothing to flip.
            CardPillContent(card: nil, deckColor: color, layout: model.cardLayout, notchWidth: model.notchWidth)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Card: no cards in this deck")
                .accessibilityHint("Opens the study card")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.onToggleExpanded() }
        }
    }

    /// What VoiceOver says for the resting notch: the deck and position, or for the streak pill the
    /// streak and today's count, which is what that pill shows.
    private var clockNow: Date { Date() }

    private func restingAccessibilityLabel(_ showing: NowShowing) -> String {
        // The front only, so the flip is never announced.
        if model.restStyle == .card { return NotchCardRest.accessibilityLabel(for: showing.card) }
        if !model.hasCamera {
            switch model.session {
            case .running(let info):
                return info.accessibilityLabel(at: clockNow)
            case .recap(let result):
                return "Study session finished, \(result.text)"
            case .idle:
                if model.pillStyle == .streak, let study = model.study { return study.accessibilityText }
                if model.pillStyle == .session { return model.lastSession.map { "Study session. \($0.lastText)" } ?? "Study session. Open to start one" }
            }
        }
        return showing.accessibilitySummary
    }

    /// The study card: deck, position, skip, the card itself, and the countdown. It starts below the
    /// camera housing, never under it.
    @ViewBuilder
    private var expandedContent: some View {
        if model.cardDraft != nil {
            CardDraftEditor(model: model)
                .padding(.horizontal, 22)
                .padding(.top, NotchCard.contentTopInset(notchHeight: model.notchHeight))
                .padding(.bottom, 16)
        } else if let showing = model.showing {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    DeckIcon(color: showing.deckColor, size: 18)
                    Text(showing.deckName)
                        .font(Theme.Typography.footnote.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(showing.position) of \(showing.total)")
                        .font(Theme.Typography.micro)
                        .monospacedDigit()
                    Button(action: model.onSkip) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.TextColor.primary)
                            .frame(width: 30, height: 22)
                            .background(Capsule().fill(Theme.TextColor.primary.with(opacity: 0.16)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next card")
                }
                .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.62))

                if model.sessionsAvailable && model.pillStyle == .session {
                    HStack { SessionControls(model: model); Spacer(minLength: 0) }
                }

                Button(action: model.onFlip) {
                    FlipView(
                        angle: NotchCard.flipAngle(isFlipped: showing.isFlipped),
                        style: NotchCard.flipStyle(reduceMotion: reduceMotion),
                        front: cardFace(showing.card.front, image: showing.card.frontImage, isBack: false),
                        back: cardFace(showing.card.back, image: showing.card.backImage, isBack: true)
                    )
                    .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.55), value: showing.isFlipped)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(showing.card.id) // a new card appears at once instead of flipping from the old one
                .accessibilityHint("Flips the card")

                if model.showsExpandedContent {
                    VStack(spacing: 6) {
                        // The countdown, or once the card is turned over, how well you knew it. One
                        // fixed height, so the card doesn't resize when it flips.
                        ZStack {
                            if showing.isFlipped && model.canGrade {
                                GradeButtons(intervals: showing.gradeIntervals, onGrade: model.onGrade)
                            } else {
                                CountdownRow(nextRotation: model.nextRotation, interval: model.rotationInterval)
                            }
                        }
                        .frame(height: 34)
                        HStack(spacing: 8) {
                            if let study = model.study {
                                Text(study.openLine)
                                    .font(Theme.Typography.micro)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.55))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .accessibilityLabel(study.accessibilityText)
                            }
                            Spacer(minLength: 8)
                            // With the session style chosen the controls come first, under the header.
                            if model.sessionsAvailable && model.pillStyle != .session { SessionControls(model: model) }
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, NotchCard.contentTopInset(notchHeight: model.notchHeight))
            .padding(.bottom, 16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Study card, \(showing.accessibilitySummary)")
            .accessibilityAction(named: "Close card") { model.onToggleExpanded() }
        } else {
            Text("Open FishBrain to add cards")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.62))
                .padding(.top, NotchCard.contentTopInset(notchHeight: model.notchHeight))
        }
    }

    private func cardFace(_ text: String, image: CardImage?, isBack: Bool) -> some View {
        CardFace(text: text, isBack: isBack, size: .small, minimumScaleFactor: 0.5, image: image, useThumbnail: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.TextColor.primary.with(opacity: 0.09)))
    }
}

/// Progress bar and "m:ss" for the current card. Ticks once a second, and only exists while the
/// notch is open.
struct CountdownRow: View {
    var nextRotation: Date
    var interval = CardScheduler.defaultInterval

    @Environment(\.accentChoice) private var accent

    private static var nextWholeSecond: Date {
        Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.up))
    }

    var body: some View {
        TimelineView(.periodic(from: Self.nextWholeSecond, by: 1)) { context in
            HStack(spacing: 8) {
                CountdownProgressBar(progress: NotchCard.progress(until: nextRotation, now: context.date, interval: interval), height: 3)
                Text(NowShowing.format(seconds: NotchCard.secondsRemaining(until: nextRotation, now: context.date)))
                    .font(Theme.Typography.micro)
                    .monospacedDigit()
                    .foregroundStyle(Theme.TextColor.primary.with(opacity: 0.55))
                    .fixedSize()
            }
        }
    }
}

/// Owns the notch panel. At rest the panel is a thin strip around the notch that ignores the mouse,
/// so clicks go to whatever is underneath; a global mouse-moved monitor (which needs no
/// Accessibility permission) opens it when the pointer reaches it. Open, the panel takes mouse
/// events; once the pointer leaves, it closes and goes back to ignoring them.
@MainActor
final class NotchController {
    let model = NotchModel()
    private(set) var panel: NotchPanel?
    private(set) var pendingExpand: Task<Void, Never>?
    private(set) var pendingCollapse: Task<Void, Never>?
    private(set) var pendingFinishCollapse: Task<Void, Never>?
    private var rotationTimer: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var timeObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var monitors: [Any] = []
    private var watcher: DirectoryWatcher?
    private var subscriptions: [AnyCancellable] = []

    private let placementProvider: @MainActor () -> NotchPlacement?
    /// Whether this notch may show right now (which display it is on, full screen, the settings).
    /// The display manager sets this; on its own a controller shows whenever "Show in notch" is on.
    private let visibilityGate: @MainActor () -> Bool
    private let showsPanel: Bool
    private let installsMonitors: Bool
    private let expandDelay: Duration
    private let collapseDelay: Duration
    private let collapseAnimation: Duration
    private let watchDirectory: URL?
    /// The current time; injectable so tests can pin it.
    private let clock: () -> Date
    private var deckStore: DeckStore { deckStoreProvider() }
    private let deckStoreProvider: @MainActor () -> DeckStore
    private let playbackStoreProvider: @MainActor () -> PlaybackStore
    private let settingsStoreProvider: @MainActor () -> SettingsStore
    private let studyStoreProvider: (@MainActor () -> StudyStore)?
    private let sessionStoreProvider: (@MainActor () -> SessionStore)?
    /// Who runs the study clock, when a Review sprint can share it with the session.
    private let studyClockProvider: (@MainActor () -> StudyClockGate)?
    /// Brings the app forward to a running sprint.
    private let goToSprint: @MainActor () -> Void
    private let copyStoreProvider: (@MainActor () -> CopyOfferStore)?
    /// What is on the clipboard, read only when the user asks for a card from it.
    private let clipboardText: @MainActor () -> String?

    /// - Parameters:
    ///   - placementProvider: where the notch is right now; the real displays by default.
    ///   - showsPanel / installsMonitors: false only in tests, so they don't put a window on screen
    ///     or listen to the real mouse.
    init(
        placementProvider: @escaping @MainActor () -> NotchPlacement? = { NotchController.currentPlacement()?.placement },
        visibilityGate: @escaping @MainActor () -> Bool = { true },
        showsPanel: Bool = true,
        installsMonitors: Bool = true,
        expandDelay: Duration = .milliseconds(120),
        collapseDelay: Duration = .milliseconds(250),
        collapseAnimation: Duration = .milliseconds(450),
        watchDirectory: URL? = nil,
        clock: @escaping () -> Date = Date.init,
        deckStore: @escaping @MainActor () -> DeckStore = { AppEnvironment.shared.deckStore },
        playbackStore: @escaping @MainActor () -> PlaybackStore = { AppEnvironment.shared.playbackStore },
        settingsStore: @escaping @MainActor () -> SettingsStore = { AppEnvironment.shared.settingsStore },
        studyStore: (@MainActor () -> StudyStore)? = nil,
        sessionStore: (@MainActor () -> SessionStore)? = nil,
        studyClock: (@MainActor () -> StudyClockGate)? = nil,
        goToSprint: @escaping @MainActor () -> Void = { NotchController.bringAppForward() },
        copyStore: (@MainActor () -> CopyOfferStore)? = nil,
        clipboardText: @escaping @MainActor () -> String? = { NSPasteboard.general.string(forType: .string) }
    ) {
        self.placementProvider = placementProvider
        self.visibilityGate = visibilityGate
        self.showsPanel = showsPanel
        self.installsMonitors = installsMonitors
        self.expandDelay = expandDelay
        self.collapseDelay = collapseDelay
        self.collapseAnimation = collapseAnimation
        self.watchDirectory = watchDirectory
        self.clock = clock
        self.deckStoreProvider = deckStore
        self.playbackStoreProvider = playbackStore
        self.settingsStoreProvider = settingsStore
        self.studyStoreProvider = studyStore
        self.sessionStoreProvider = sessionStore
        self.studyClockProvider = studyClock
        self.goToSprint = goToSprint
        self.copyStoreProvider = copyStore
        self.clipboardText = clipboardText
    }

    /// Where the notch goes on one display, or nil once that display is gone.
    static func placement(forDisplayID id: UInt32, screens: [NSScreen] = NSScreen.screens) -> NotchPlacement? {
        screens.first { $0.displayID == id }.map { NotchGeometry.placement(for: ScreenMetrics($0)) }
    }

    /// The placement for the current displays, or nil with no display.
    static func currentPlacement(screens: [NSScreen] = NSScreen.screens) -> (screen: NSScreen, placement: NotchPlacement)? {
        let metrics = screens.map(ScreenMetrics.init)
        guard let index = NotchGeometry.chooseScreen(metrics) else { return nil }
        return (screens[index], NotchGeometry.placement(for: metrics[index]))
    }

    // MARK: Frames

    /// The strip beside the camera grows for long text; the offer's "+ Card" chip needs more than a position.
    private var wing: CGFloat {
        NotchGeometry.wing(forPositionText: model.banner.map { $0.isOffer ? "+ Card" : "✓ Added" } ?? model.showing?.positionText)
    }

    var collapsedFrame: CGRect? { placementProvider().map(collapsedFrame(for:)) }

    /// A real notch gets a wing either side of the camera; a drawn pill is as wide as its content.
    /// The Card style is the size of a real notch where it is drawn, and puts the text in a wider
    /// left wing beside a real camera. An offer takes over either, as before.
    private func collapsedFrame(for placement: NotchPlacement) -> CGRect {
        let isCard = model.banner == nil && restStyle(for: placement) == .card
        if placement.hasNotch {
            guard isCard else { return placement.alignedCollapsedFrame(wing: wing) }
            return cardLayout(for: placement) == .besideCamera
                ? placement.alignedSnugFrame()
                : placement.alignedCollapsedFrame(wing: NotchGeometry.collapsedWing)
        }
        if isCard { return placement.alignedCardFrame() }
        return placement.alignedDrawnFrame(width: model.banner != nil
            ? NotchGeometry.bannerRestWidth
            : NotchGeometry.drawnWidth(forPositionText: model.showing?.positionText, style: model.restStyle))
    }

    /// `model.restStyle` for this placement (the model's `hasCamera` may not have caught up yet).
    private func restStyle(for placement: NotchPlacement) -> PillStyle {
        guard !placement.hasNotch else { return PillStyle.onRealNotch(model.pillStyle) }
        return model.restStyle
    }

    /// Beside a camera with no card to show, only the deck color shows, so the wing stays narrow.
    private func cardLayout(for placement: NotchPlacement) -> CardRestLayout {
        let layout = placement.cardLayout
        return layout == .besideCamera && model.showing == nil ? .deckOnly : layout
    }

    var expandedFrame: CGRect? {
        placementProvider().map { placement in
            let size = NotchGeometry.expandedSize
            let frame = placement.frame(size: size)
            return CGRect(x: frame.minX.rounded(), y: placement.screenFrame.maxY - size.height, width: size.width, height: size.height)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard panel == nil else { return }
        let panel = NotchPanel()
        // The SwiftUI view goes inside a plain container, not in as the window's content view.
        // A hosting view that *is* the content view resizes its window to fit its largest child, which
        // stops the panel being a thin strip at rest. The controller alone decides the panel's size.
        let hosting = FirstMouseHostingView(rootView: NotchRootView(model: model))
        hosting.sizingOptions = []
        let container = FirstMouseContainerView()
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        panel.ignoresMouseEvents = true // collapsed: clicks go to whatever is underneath
        self.panel = panel

        model.onFlip = { [weak self] in self?.flipCurrent() }
        model.onSkip = { [weak self] in self?.skipCurrent() }
        model.onAcceptOffer = { [weak self] in self?.acceptOffer() }
        model.onSaveDraft = { [weak self] in self?.saveDraft() }
        model.onCancelDraft = { [weak self] in self?.cancelDraft() }
        model.onGrade = { [weak self] grade in self?.gradeCurrent(grade) }
        model.onStartSession = { [weak self] minutes in self?.startSession(minutes: minutes) }
        model.onEndSession = { [weak self] in self?.endSession() }
        model.onGoToSprint = { [weak self] in self?.goToSprint() }
        model.onSetSessionMinutes = { [weak self] minutes in
            self?.sessionStoreProvider?().setPreferredMinutes(minutes)
            self?.refreshContent()
        }
        model.onToggleExpanded = { [weak self] in
            guard let self else { return }
            if self.model.isExpanded { self.collapse() } else { self.expand() }
        }
        panel.setAccessibilityLabel("FishBrain notch")
        bindContent()

        // Plugging in or removing a display, changing resolution, rearranging displays.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        // The next-card timer was set against the old time: after sleep, or when the clock or time
        // zone changes, work out the current card again.
        let wakeEvents: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
            (NotificationCenter.default, .NSSystemClockDidChange),
            (NotificationCenter.default, .NSSystemTimeZoneDidChange),
            // Midnight: today's count and the streak start a new day.
            (NotificationCenter.default, .NSCalendarDayChanged),
        ]
        timeObservers = wakeEvents.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshContent() }
            })
        }
        // Nothing at rest animates while the panel can't be seen: the display asleep, the screen
        // locked or the panel covered (both show up as the panel no longer being visible).
        let workspace = NSWorkspace.shared.notificationCenter
        timeObservers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRestVisibility() }
        }))
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            timeObservers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = asleep
                    self?.updateRestVisibility()
                }
            }))
        }
        applyVisibility()
    }

    private var screensAsleep = false

    private func updateRestVisibility() {
        guard let panel else { return }
        let visible = !screensAsleep && (!showsPanel || panel.occlusionState.contains(.visible))
        if model.restIsVisible != visible { model.restIsVisible = visible }
    }

    func stop() {
        deactivate()
        timeObservers.forEach { $0.center.removeObserver($0.token) }
        timeObservers = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        subscriptions = []
        panel = nil
    }

    // MARK: Showing and hiding ("Show in notch")

    /// Whether the notch is on screen and listening. Off, it is hidden and nothing runs.
    private(set) var isShowing = false

    private func applyVisibility() {
        let wanted = settingsStoreProvider().showsNotch && visibilityGate()
        if wanted && !isShowing {
            activate()
        } else if !wanted && isShowing {
            deactivate()
        }
    }

    private func activate() {
        guard panel != nil, !isShowing else { return }
        isShowing = true
        reposition()
        if showsPanel { panel?.orderFrontRegardless() }
        if installsMonitors { installPointerMonitors() }
        // The widget skipping or flipping rewrites a file in the shared folder; the kernel tells us.
        watcher = DirectoryWatcher(directory: watchDirectory ?? AppGroup.storageDirectory()) { [weak self] in
            MainActor.assumeIsolated {
                self?.playbackStoreProvider().refresh()
                self?.studyStoreProvider?().refresh()
            }
        }
        refreshContent()
    }

    /// Hides the panel at once and stops everything it was listening to: the mouse monitors, the
    /// folder watcher and the next-card timer. Turned back on, it picks everything up again.
    private func deactivate() {
        model.cardDraft = nil
        panel?.releaseKeyboard()
        pendingExpand?.cancel()
        pendingCollapse?.cancel()
        pendingFinishCollapse?.cancel()
        pendingExpand = nil
        pendingCollapse = nil
        pendingFinishCollapse = nil
        rotationTimer?.cancel()
        rotationTimer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        watcher?.cancel()
        watcher = nil
        model.isExpanded = false
        model.showsExpandedContent = false
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
        isShowing = false
    }

    // MARK: Content

    /// Keeps the notch in step with the library, playback state and settings, without polling.
    private func bindContent() {
        let decks = deckStore
        let playback = playbackStoreProvider()
        let settings = settingsStoreProvider()

        let changes = decks.objectWillChange.merge(with: playback.objectWillChange, settings.objectWillChange)
        let withStudy = studyStoreProvider.map { changes.merge(with: $0().objectWillChange).eraseToAnyPublisher() } ?? changes.eraseToAnyPublisher()
        let withSession = sessionStoreProvider.map { withStudy.merge(with: $0().objectWillChange).eraseToAnyPublisher() } ?? withStudy
        let withClock = studyClockProvider.map { withSession.merge(with: $0().objectWillChange).eraseToAnyPublisher() } ?? withSession
        let observed = copyStoreProvider.map { withClock.merge(with: $0().objectWillChange).eraseToAnyPublisher() } ?? withClock
        observed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshContent() }
            .store(in: &subscriptions)
    }

    /// The deck the notch studies: the one chosen in settings, or the first deck if none was chosen
    /// or the chosen one was deleted (the same rule the widgets use).
    private var shownDeck: Deck? {
        if let id = sessionStoreProvider?().active?.deckID, let deck = deckStore.decks.first(where: { $0.id == id }) { return deck }
        return DeckSelection.resolve(settingsStoreProvider().notchDeckID, in: deckStore.decks)
    }

    func refreshContent(at date: Date? = nil) {
        applyVisibility()
        guard isShowing else { return }
        let date = date ?? clock()
        // A session whose time is up (or whose deck was deleted) ends here, so a Mac that slept
        // through the end shows the recap on wake.
        let sessions = sessionStoreProvider?()
        sessions?.expireIfNeeded(at: date)
        if let active = sessions?.active, !deckStore.decks.contains(where: { $0.id == active.deckID }) { sessions?.end(at: date) }
        let active = sessions?.active
        let scheduler = active?.scheduler ?? CardScheduler()

        let deck = shownDeck
        let state = active?.playback ?? deck.map { playbackStoreProvider().state(for: $0.id) } ?? PlaybackState()
        let showing = deck.flatMap { NowShowing.make(deck: $0, state: state, at: date, scheduler: scheduler) }

        // A new card (rotation, skip, a grade, another deck) always starts on its front.
        if model.showing?.card.id != showing?.card.id || model.showing?.deckID != showing?.deckID { model.restStartedAt = date }
        if model.showing != showing { model.showing = showing }
        let emptyColor = showing == nil ? deck?.color : nil
        if model.emptyDeckColor != emptyColor { model.emptyDeckColor = emptyColor }
        let interval = settingsStoreProvider().notchFlipInterval
        if model.flipInterval != interval {
            model.flipInterval = interval
            model.restStartedAt = date
        }
        let next = scheduler.nextRotation(after: date)
        if model.nextRotation != next { model.nextRotation = next }
        if model.rotationInterval != scheduler.interval { model.rotationInterval = scheduler.interval }
        if model.accent != settingsStoreProvider().accent { model.accent = settingsStoreProvider().accent }
        let study = studyStoreProvider.map { provider -> StudySummary in
            let store = provider()
            store.refresh()
            return store.summary(at: date, goal: settingsStoreProvider().dailyGoal)
        }
        if model.study != study { model.study = study }
        if let sessions { applySession(sessions.session, sprint: studyClockProvider?().sprint, at: date) }
        applyBanner(at: date)
        let choices = deckStore.decks.map { DeckChoice(id: $0.id, name: $0.name) }
        if model.deckChoices != choices { model.deckChoices = choices }
        let style = PillStyle.resolved(settingsStoreProvider().pillStyle)
        if model.pillStyle != style { model.pillStyle = style }
        reposition()
        updateKeyboardAccess()
        updateMousePassthrough()
        scheduleRotationRefresh(after: date, session: sessions?.session)
    }

    /// The offer (or the note that a card was made) is shared by every display; when a new offer
    /// arrives it is announced to VoiceOver, since nothing else would draw attention to it.
    private func applyBanner(at date: Date) {
        guard let store = copyStoreProvider?() else { return }
        store.expireIfNeeded(at: date)
        let banner = store.banner
        guard model.banner != banner else { return }
        let isNew = banner != nil && banner?.kind != model.banner?.kind
        model.banner = banner
        if isNew, showsPanel, let banner, let panel {
            NSAccessibility.post(
                element: panel, notification: .announcementRequested,
                userInfo: [.announcement: banner.announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
        }
    }

    /// At rest the panel lets clicks through to whatever is underneath. An offer is the one exception:
    /// it is a button, so the panel takes clicks while it shows.
    private func updateMousePassthrough() {
        guard let panel, !model.showsExpandedContent else { return }
        panel.ignoresMouseEvents = model.banner?.isOffer != true
    }

    /// With "Grade with the keyboard" on, the notch takes the keyboard only while it is open on a
    /// turned-over card with the grade buttons showing, and gives it back the moment that stops being
    /// true. Off (the default), it never takes focus from the app in front.
    private func updateKeyboardAccess() {
        guard let panel else { return }
        let grading = settingsStoreProvider().keyboardGrading && showsPanel && model.isExpanded && model.canGrade && model.showing?.isFlipped == true
        // Writing a card needs the keyboard whatever that setting says: it is what the user just asked for.
        let writing = showsPanel && model.isExpanded && model.cardDraft != nil
        if grading || writing {
            if !panel.allowsKeyboard {
                panel.allowsKeyboard = true
                panel.makeKey()
            }
        } else if panel.allowsKeyboard {
            panel.releaseKeyboard()
        }
    }

    private func applySession(_ session: StudySession, sprint: StudyClockInfo?, at date: Date) {
        // One value for the notch whichever kind of clock is running (a sprint, if there is one).
        let phase: SessionPhase
        switch StudyClockGate.phase(session: session, sprint: sprint, at: date) {
        case .running(let info): phase = .running(info)
        case .recap(let result): phase = .recap(result)
        case .idle: phase = .idle
        }
        if model.session != phase { model.session = phase }
        if model.lastSession != session.last { model.lastSession = session.last }
        if model.sessionMinutes != session.preferredMinutes { model.sessionMinutes = session.preferredMinutes }
        if !model.sessionsAvailable { model.sessionsAvailable = true }
    }

    /// One timer, set for the next moment something changes: the card rotating, the session ending,
    /// or its recap going away. Nothing ticks in between.
    private func scheduleRotationRefresh(after date: Date, session: StudySession?) {
        rotationTimer?.cancel()
        let scheduler = session?.active?.scheduler ?? CardScheduler()
        var next = scheduler.nextRotation(after: date)
        if let end = session?.active?.endsAt { next = min(next, end) }
        if let recapUntil = session?.recapUntil, recapUntil > date { next = min(next, recapUntil) }
        if let expires = copyStoreProvider?().banner?.expiresAt, expires > date { next = min(next, expires) }
        rotationTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0) + 0.05))
            guard !Task.isCancelled else { return }
            self?.refreshContent()
        }
    }

    // MARK: Positioning

    func reposition() {
        guard let panel, let placement = placementProvider() else { return }
        let collapsed = collapsedFrame(for: placement)
        model.hasCamera = placement.hasNotch
        let layout = cardLayout(for: placement)
        if model.cardLayout != layout { model.cardLayout = layout }
        model.collapsedSize = collapsed.size
        model.notchWidth = placement.notchFrame.width
        model.notchHeight = placement.notchFrame.height
        guard let frame = model.isExpanded ? expandedFrame : collapsed else { return }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    // MARK: Studying from the notch

    /// Flips the shown card. This goes through the shared playback state, which saves it and
    /// refreshes the widgets, so a widget showing the same deck flips too.
    func flipCurrent() {
        guard let deck = shownDeck else { return }
        if let sessions = sessionStoreProvider?(), sessions.active != nil {
            sessions.flip(in: deck, at: clock())
        } else {
            playbackStoreProvider().flip(deck, at: clock())
        }
        refreshContent()
    }

    /// Grades the shown card (it is turned over), which schedules its next review and moves on. Not
    /// in a study session, which keeps its own rotation.
    func gradeCurrent(_ grade: ReviewGrade) {
        guard let deck = shownDeck, sessionStoreProvider?().active == nil else { return }
        playbackStoreProvider().grade(grade, deck, at: clock())
        refreshContent()
    }

    func skipCurrent() {
        guard let deck = shownDeck else { return }
        if let sessions = sessionStoreProvider?(), sessions.active != nil {
            sessions.skip(in: deck, at: clock())
        } else {
            playbackStoreProvider().skip(deck, at: clock())
        }
        refreshContent()
    }

    // MARK: Copy to card

    /// Opens the card editor, on `front`, in the deck the notch studies. With no deck there is nowhere
    /// to put a card, so nothing opens.
    func beginCardDraft(front: String) {
        guard isShowing, let deck = shownDeck ?? deckStore.decks.first else { return }
        copyStoreProvider?().dismiss()
        model.cardDraft = CardDraft(front: front, deckID: deck.id)
        pendingCollapse?.cancel()
        pendingCollapse = nil
        if model.isExpanded { updateKeyboardAccess() } else { expand() }
        refreshContent()
    }

    /// The offer was clicked: the editor opens on the copied text (read now if it wasn't before).
    func acceptOffer() {
        guard case .offer(let text)? = model.banner?.kind else { return }
        beginCardDraft(front: text ?? CopyCandidate.prefill(from: clipboardText()))
    }

    /// Adds the card to the end of the chosen deck, as any edit does (so the widgets refresh), says so for
    /// a moment, and gives the keyboard back.
    func saveDraft() {
        guard let draft = model.cardDraft else { return }
        let front = draft.front.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !front.isEmpty,
              let deck = deckStore.decks.first(where: { $0.id == draft.deckID }) ?? shownDeck ?? deckStore.decks.first,
              deckStore.addCard(to: deck.id, front: front, back: draft.back.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        else { return }
        copyStoreProvider?().showAdded(deckName: deck.name, at: clock())
        closeDraft()
    }

    func cancelDraft() {
        closeDraft()
    }

    private func closeDraft() {
        model.cardDraft = nil
        collapse()
        updateKeyboardAccess()
        refreshContent()
    }

    // MARK: Study session

    /// Brings FishBrain's main window forward: where a running Review sprint is.
    static func bringAppForward() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.styleMask.contains(.titled) && !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Starts a session on the card showing now, in the deck the notch studies.
    func startSession(minutes: Int) {
        guard let sessions = sessionStoreProvider?(), sessions.active == nil, studyClockProvider?().isSprintRunning != true,
              let deck = shownDeck, let showing = model.showing else { return }
        sessions.start(deckID: deck.id, currentIndex: showing.position - 1, minutes: minutes, at: clock())
        refreshContent()
    }

    func endSession() {
        sessionStoreProvider?().end(at: clock())
        refreshContent()
    }

    // MARK: Hover

    private func installPointerMonitors() {
        // Fires for every mouse move in other apps. The handler is a couple of comparisons.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            let pointer = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handlePointer(pointer) }
        }) { monitors.append(global) }
        // And moves over the panel itself (the global monitor doesn't see events for our own windows).
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            let pointer = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handlePointer(pointer) }
            return event
        }) { monitors.append(local) }
    }

    var hasPointerMonitors: Bool { !monitors.isEmpty }
    /// Whether the folder watcher and the next-card timer are running (they stop while hidden).
    var isListeningForChanges: Bool { watcher != nil }
    var hasRotationTimer: Bool { rotationTimer != nil }

    /// Decides from the pointer position whether to open or close.
    func handlePointer(_ pointer: CGPoint) {
        guard panel != nil, isShowing else { return }
        if model.isExpanded {
            // Writing a card: the notch stays open however the pointer wanders.
            if model.cardDraft != nil {
                pendingCollapse?.cancel()
                pendingCollapse = nil
                return
            }
            guard let expanded = expandedFrame else { return }
            if NotchHover.shouldCollapse(pointer: pointer, expandedFrame: expanded) {
                scheduleCollapse()
            } else {
                pendingCollapse?.cancel()
                pendingCollapse = nil
            }
        } else {
            // An offer is for clicking: opening the study card over it would hide it.
            if model.banner?.isOffer == true {
                pendingExpand?.cancel()
                pendingExpand = nil
                return
            }
            guard let collapsed = collapsedFrame, NotchHover.shouldExpand(pointer: pointer, collapsedFrame: collapsed) else {
                pendingExpand?.cancel()
                pendingExpand = nil
                return
            }
            scheduleExpand()
        }
    }

    /// A short dwell, so the pointer flying past on its way to a menu doesn't open it.
    private func scheduleExpand() {
        guard pendingExpand == nil else { return }
        pendingExpand = Task { [weak self, expandDelay] in
            try? await Task.sleep(for: expandDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingExpand = nil
            self.expand()
        }
    }

    private func scheduleCollapse() {
        guard pendingCollapse == nil else { return }
        pendingCollapse = Task { [weak self, collapseDelay] in
            try? await Task.sleep(for: collapseDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingCollapse = nil
            self.collapse()
        }
    }

    func expand() {
        guard let panel, !model.isExpanded, let frame = expandedFrame else { return }
        pendingFinishCollapse?.cancel()
        // Make room first, then let the view spring open into it. Open, the panel takes mouse events.
        panel.setFrame(frame, display: true)
        panel.ignoresMouseEvents = false
        model.showsExpandedContent = true
        model.isExpanded = true
        updateKeyboardAccess()
    }

    func collapse() {
        guard model.isExpanded else { return }
        model.isExpanded = false
        updateKeyboardAccess()
        // Let the spring finish inside the big window, then shrink it and hand clicks back.
        pendingFinishCollapse?.cancel()
        pendingFinishCollapse = Task { [weak self, collapseAnimation] in
            try? await Task.sleep(for: collapseAnimation)
            guard !Task.isCancelled, let self, !self.model.isExpanded else { return }
            self.panel?.ignoresMouseEvents = true
            self.model.showsExpandedContent = false // stops the countdown ticking
            self.model.restStartedAt = self.clock() // back at rest: the front, and the count starts again
            self.reposition()
            self.updateMousePassthrough() // an offer may be waiting to be clicked
        }
    }
}

#if DEBUG
/// `-FishBrainPrintNotch`: what the notch code sees on this Mac, and where it would put the panel.
enum NotchReport {
    @MainActor
    static func print() {
        for (index, screen) in NSScreen.screens.enumerated() {
            let m = ScreenMetrics(screen)
            let p = NotchGeometry.placement(for: m)
            Swift.print("Screen \(index) \(screen.localizedName): frame \(m.frame), safeAreaTop \(m.safeAreaTop), notch \(p.hasNotch ? "yes" : "no")")
            Swift.print("   auxiliary left \(m.auxiliaryTopLeft.map(String.init(describing:)) ?? "-"), right \(m.auxiliaryTopRight.map(String.init(describing:)) ?? "-")")
            Swift.print("   notch frame \(p.notchFrame), collapsed panel \(p.alignedCollapsedFrame())")
        }
        if let target = NotchController.currentPlacement() {
            Swift.print("Chosen: \(target.screen.localizedName)")
        } else {
            Swift.print("No display")
        }
    }
}
#endif

import AppKit
import SwiftUI

/// Learn mode: one big card, flipped with a click or Space, moved with the arrow keys. No grades and
/// no timer; the only trace it leaves is that a card turned to its answer counts toward today's goal.
struct LearnView: View {
    /// The deck's name, or the subject's for "Learn all".
    var title: String
    /// One deck, or all of a subject's in the order the sidebar lists them.
    var decks: [Deck]
    /// "Learn all" through a subject: the deck of the card showing is named quietly in the top bar.
    var isWholeSubject = false
    var onLeave: () -> Void

    @EnvironmentObject private var study: StudyStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accentChoice) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: LearnModel
    @State private var hintsVisible = true

    static let cardMaxWidth: CGFloat = 700
    static let cardMaxHeight: CGFloat = 400

    init(deck: Deck, onLeave: @escaping () -> Void) {
        self.init(title: deck.name, decks: [deck], isWholeSubject: false, onLeave: onLeave)
    }

    init(title: String, decks: [Deck], isWholeSubject: Bool, onLeave: @escaping () -> Void) {
        self.title = title
        self.decks = decks
        self.isWholeSubject = isWholeSubject
        self.onLeave = onLeave
        _model = StateObject(wrappedValue: LearnModel(decks: decks))
    }

    /// The card and the deck it is in.
    private func lookup(_ id: Card.ID) -> (card: Card, deck: Deck)? {
        for deck in decks {
            if let card = deck.cards.first(where: { $0.id == id }) { return (card, deck) }
        }
        return nil
    }

    private var session: LearnSession { model.session }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 12)
            if session.isComplete {
                roundComplete
            } else {
                cardRow
            }
            Spacer(minLength: 12)
            keyHints
                .opacity(hintsVisible ? 1 : 0)
                .padding(.bottom, 18)
            LearnTrack(progress: session.progress, step: session.index, reduceMotion: reduceMotion)
                .frame(maxWidth: Self.cardMaxWidth)
                .padding(.horizontal, 32)
                .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.recordStudied = { [study, settings] id, date in
                study.recordStudied(id, at: date, goal: settings.dailyGoal)
            }
        }
        .onChange(of: decks.flatMap(\.cards).map(\.id)) { _, _ in model.sync(with: decks) }
        .onChange(of: session.currentCardID) { _, id in announce(id) }
        // The key hints are for the first moments; they fade after a few seconds.
        .task {
            try? await Task.sleep(for: .seconds(6))
            if reduceMotion { hintsVisible = false } else { withAnimation(.easeOut(duration: 1)) { hintsVisible = false } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isWholeSubject ? "Learn all, \(title)" : "Learn, \(title)")
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("Leave Learn", action: onLeave)
                .buttonStyle(.capsuleSecondary)
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Goes back to the deck")
            Spacer(minLength: 12)
            VStack(spacing: 1) {
                Text("\(title) · \(isWholeSubject ? "Learn all" : "Learn")")
                    .lineLimit(1)
                // The deck of the card showing, quietly, when the cards come from several decks.
                if isWholeSubject, let current = session.currentCardID, let deck = lookup(current)?.deck {
                    Text(deck.name)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.secondary.with(opacity: 0.8))
                        .lineLimit(1)
                        .accessibilityLabel("Deck, \(deck.name)")
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                Text(session.positionText)
                    .monospacedDigit()
                    .accessibilityLabel(session.isEmpty ? "No cards" : "Card \(session.isComplete ? session.total : session.index + 1) of \(session.total)")
                Button { model.shuffle() } label: {
                    Image(systemName: "shuffle")
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: [])
                .accessibilityLabel("Shuffle")
                .accessibilityHint("Mixes the order and starts again")
                .help("Shuffle (S)")
            }
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.TextColor.secondary)
        .padding(.leading, 100) // the window's traffic lights sit over the hidden title bar
        .padding(.trailing, 28)
        .padding(.top, 14)
    }

    // MARK: The card

    private var currentCard: Card? {
        session.currentCardID.flatMap { lookup($0)?.card }
    }

    private var cardRow: some View {
        HStack(spacing: 28) {
            arrow("chevron.left", label: "Previous card", key: .leftArrow, enabled: session.canGoBack) { model.previous() }
            cardButton
            arrow("chevron.right", label: "Next card", key: .rightArrow, enabled: session.canGoForward) { model.next() }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: Self.cardMaxWidth + 2 * (48 + 28) + 56)
    }

    @ViewBuilder
    private var cardButton: some View {
        if let card = currentCard {
            Button { model.flip() } label: {
                FlipView(
                    angle: NotchCard.flipAngle(isFlipped: session.isFlipped),
                    style: NotchCard.flipStyle(reduceMotion: reduceMotion),
                    front: face(card, isBack: false),
                    back: face(card, isBack: true)
                )
                .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.55), value: session.isFlipped)
                .frame(maxWidth: Self.cardMaxWidth, maxHeight: Self.cardMaxHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .id(card.id) // a new card appears at once instead of flipping from the old one
            .accessibilityLabel(CardFace.accessibilityText(
                session.isFlipped ? card.back : card.front, isBack: session.isFlipped,
                image: session.isFlipped ? card.backImage : card.frontImage
            ))
            .accessibilityHint("Flips the card")
            .accessibilityAction(named: "Next card") { model.next() }
            .accessibilityAction(named: "Previous card") { model.previous() }
            .accessibilityAction(named: "Shuffle") { model.shuffle() }
            .accessibilityAction(named: "Leave Learn") { onLeave() }
        } else {
            Spacer().frame(maxWidth: Self.cardMaxWidth, maxHeight: Self.cardMaxHeight)
        }
    }

    private func face(_ card: Card, isBack: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.widget, style: .continuous)
        return CardFace(
            text: isBack ? card.back : card.front, isBack: isBack, size: .hero,
            image: isBack ? card.backImage : card.frontImage
        )
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(isBack ? accent.flippedSurface : Theme.Surface.widget))
        .overlay { shape.strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
    }

    private func arrow(_ symbol: String, label: String, key: KeyEquivalent, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.TextColor.primary)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Theme.Surface.control))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    // MARK: End of the round

    private var roundComplete: some View {
        VStack(spacing: 18) {
            Text("Round complete")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.TextColor.primary)
            Text(session.total == 1 ? "1 card" : "\(session.total) cards")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.TextColor.secondary)
            HStack(spacing: 10) {
                Button("Go again") { model.goAgain() }
                    .buttonStyle(.capsulePrimary)
                    .keyboardShortcut(.defaultAction)
                Button("Leave", action: onLeave)
                    .buttonStyle(.capsuleSecondary)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: Self.cardMaxWidth, minHeight: 240)
        .accessibilityElement(children: .contain)
    }

    // MARK: Hints

    private var keyHints: some View {
        HStack(spacing: 22) {
            hint(["Space"], "flip")
            hint(["←", "→"], "move")
            hint(["S"], "shuffle")
            hint(["Esc"], "leave")
        }
        .font(Theme.Typography.footnote)
        .foregroundStyle(Theme.TextColor.secondary)
        .accessibilityHidden(true)
    }

    private func hint(_ keys: [String], _ action: String) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .foregroundStyle(Theme.TextColor.cardBack)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.Surface.control))
            }
            Text(action)
        }
    }

    /// Reads the new card out when VoiceOver is on, since focus stays on the arrow that was pressed.
    private func announce(_ id: Card.ID?) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let id, let card = lookup(id)?.card else { return }
        let text = "Card \(session.index + 1) of \(session.total). " + CardFace.accessibilityText(card.front, isBack: false, image: card.frontImage)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: text])
    }
}

/// A hairline along the bottom with a small fish on it: where you are in the round. It swims between
/// cards; with Reduce Motion it steps instead.
struct LearnTrack: View {
    var progress: Double
    /// Which way the tail leans; changes on every move so the tail flicks as the fish swims.
    var step: Int
    var reduceMotion: Bool
    /// What VoiceOver calls the track.
    var label = "Progress"

    @Environment(\.accentChoice) private var accent

    var body: some View {
        GeometryReader { geometry in
            let offset = FishSwim.offset(progress: progress, trackWidth: geometry.size.width, fishWidth: FishView.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Surface.progressTrack).frame(height: 2)
                Capsule().fill(accent.light.with(opacity: 0.55)).frame(width: offset + FishView.size.width / 2, height: 2)
                FishView(color: accent.light.color, tailAngle: reduceMotion ? 0 : (step % 2 == 0 ? 16 : -16))
                    .offset(x: offset)
            }
            .frame(maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: progress)
        }
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

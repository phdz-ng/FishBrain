import AppKit
import SwiftUI

/// Square preview, styled like the widget, of the card the widgets and notch show right now, with the
/// four grade buttons under it and today's count below. Ticks every second so the progress bar and
/// countdown stay live.
///
/// Double-click the text (or press Return on the focused card, or use the Edit card action) to edit the
/// side showing in place. While editing, the preview holds that card (see `PreviewCardEdit`), Cancel and
/// Save take the grade buttons' place, and the panel keeps its height.
struct NowShowingPanel: View {
    /// Wide enough for four grade buttons ("Again" over "1 min") side by side.
    static let side: CGFloat = 280
    /// Everything but the card: the label, the four buttons, the countdown row and today's line, and
    /// the gaps between them.
    static let chromeHeight: CGFloat = 172
    static let minimumCardHeight: CGFloat = 150

    /// The card keeps its square when there is room and gives up height, down to a floor, when the
    /// window is short, so the buttons under it stay in view.
    static func cardHeight(available: CGFloat) -> CGFloat {
        min(side, max(minimumCardHeight, available - chromeHeight))
    }

    var deck: Deck
    var state: PlaybackState
    var onFlip: () -> Void
    var onSkip: () -> Void
    var onGrade: (ReviewGrade) -> Void = { _ in }
    /// Today's count and streak for a given moment; nil leaves the line out.
    var studySummary: (Date) -> StudySummary? = { _ in nil }
    /// Square unless the window is short; see `cardHeight(available:)`.
    var cardHeight: CGFloat = NowShowingPanel.side
    /// Editing in place, shared with the card table so its row shows the draft.
    @ObservedObject var edit = PreviewCardEdit()
    /// Save: writes the draft (`PreviewCardEdit.save(to:)`).
    var onSave: () -> Void = {}

    @Environment(\.accentChoice) private var accent
    @State private var isHovering = false
    @State private var isHoveringText = false
    /// The flip a single click has set up, waiting out the double-click interval.
    @State private var pendingFlip: Task<Void, Never>?

    /// Ticking on whole seconds keeps the countdown from flipping at odd sub-second moments.
    private static var nextWholeSecond: Date {
        Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.up))
    }

    private var draft: PreviewCardEdit.Draft? {
        guard let draft = edit.draft, draft.deckID == deck.id else { return nil }
        return draft
    }

    static func label(isEditing: Bool) -> String { isEditing ? "Editing card" : "Now showing" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.label(isEditing: draft != nil))
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.TextColor.secondary)

            TimelineView(.periodic(from: Self.nextWholeSecond, by: 1)) { context in
                let live = NowShowing.make(deck: deck, state: state, at: context.date)
                let showing = edit.displayed(live: live, deckID: deck.id)
                VStack(alignment: .leading, spacing: 12) {
                    card(showing)
                    grading(showing)
                    caption(showing)
                    if let summary = studySummary(context.date) { studyLine(summary) }
                }
            }
        }
        .frame(width: Self.side, alignment: .leading)
        .onDisappear { pendingFlip?.cancel() }
    }

    /// A card has to be turned over to be graded.
    static func canGrade(_ showing: NowShowing?) -> Bool { showing?.isFlipped == true }

    /// Always there, so the panel doesn't change height when the card turns over: dimmed and disabled
    /// while the front is showing. No bare 1 to 4 keys here; they would fight with typing in the list.
    /// While editing, Cancel and Save sit in the same space and the grade buttons are hidden under them.
    private func grading(_ showing: NowShowing?) -> some View {
        let isEditing = draft != nil
        return ZStack {
            GradeButtons(
                intervals: showing?.gradeIntervals ?? .forNewCard,
                size: .roomy,
                usesShortcuts: false,
                onGrade: onGrade
            )
            .disabled(!Self.canGrade(showing) || isEditing)
            .opacity(isEditing ? 0 : 1)
            .accessibilityHidden(isEditing)
            if isEditing {
                EditButtons(onCancel: { edit.cancel() }, onSave: onSave)
            }
        }
    }

    private func studyLine(_ summary: StudySummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill")
                .foregroundStyle(Theme.Streak.flame)
                .accessibilityHidden(true)
            Text(summary.openLine)
                .monospacedDigit()
                .accessibilityLabel(summary.accessibilityText)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.TextColor.cardBack)
    }

    private func card(_ showing: NowShowing?) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.widget, style: .continuous)
        let isEditing = draft != nil
        return VStack(spacing: 0) {
            if let showing {
                HStack {
                    Text(showing.deckName).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 8)
                    if isHovering && !isEditing {
                        Image(systemName: "pencil")
                            .help("Double-click to edit")
                            .accessibilityHidden(true)
                    } else {
                        Text(showing.positionText).monospacedDigit()
                    }
                }
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.meta(isFlipped: showing.isFlipped))
                face(showing)
                if isEditing {
                    HStack(spacing: 6) {
                        Image(systemName: "pause.fill").accessibilityHidden(true)
                        Text("Timer paused while editing")
                    }
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.meta(isFlipped: showing.isFlipped))
                    .frame(maxWidth: .infinity)
                } else {
                    CountdownProgressBar(progress: showing.progress)
                }
            } else {
                Text("Add a card to see it here")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .frame(width: Self.side, height: cardHeight)
        .background(shape.fill(showing?.isFlipped == true ? accent.flippedSurface : Theme.Surface.widget))
        .overlay {
            if isEditing {
                shape.strokeBorder(accent.fill, lineWidth: 2)
            } else {
                shape.strokeBorder(Theme.Surface.hairline, lineWidth: 0.5)
            }
        }
        .contentShape(shape)
        .onHover { isHovering = $0 }
        // A click on the card flips it once the double-click interval has gone by; while editing, clicks
        // belong to the field.
        .gesture(TapGesture().onEnded { click(showing, onText: false) }, including: isEditing ? .subviews : .all)
        .modifier(CardKeyboardAndAccessibility(
            isEditing: isEditing,
            showing: showing,
            onFlip: onFlip,
            onEdit: { if let showing { begin(showing) } }
        ))
    }

    /// The card's picture and text, laid out like `CardFace` at its small size; while editing, the text
    /// is the field.
    @ViewBuilder
    private func face(_ showing: NowShowing) -> some View {
        let isBack = showing.isFlipped
        let image = isBack ? showing.card.backImage : showing.card.frontImage
        let text = isBack ? showing.card.back : showing.card.front
        let font = isBack ? CardFace.Size.small.backFont : CardFace.Size.small.frontFont
        let hasText = !PreviewCardEdit.trimmed(text).isEmpty
        VStack(spacing: 6) {
            if let image {
                CardPicture(image: image, thumbnail: false, store: .shared)
            }
            if let draft {
                editingField(draft)
            } else if hasText || image == nil {
                Text(text)
                    .font(font)
                    .foregroundStyle(Theme.TextColor.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(image == nil ? nil : 4)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        if isHovering {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.TextColor.primary.with(opacity: 0.07))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onHover(perform: setTextHover)
                    .onDisappear { if isHoveringText { setTextHover(false) } }
                    .onTapGesture { click(showing, onText: true) }
            }
            if isBack {
                Text("Answer")
                    .font(Theme.Typography.sectionLabel)
                    .foregroundStyle(accent.light)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(FaceAccessibility(label: draft == nil ? CardFace.accessibilityText(text, isBack: isBack, image: image) : nil))
    }

    private func editingField(_ draft: PreviewCardEdit.Draft) -> some View {
        let isBack = draft.side == .back
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return PreviewTextField(
            text: Binding(get: { edit.text }, set: { edit.text = $0 }),
            side: draft.side,
            font: .systemFont(ofSize: isBack ? 16 : 20, weight: isBack ? .medium : .bold),
            textColor: Theme.TextColor.primary,
            caretColor: accent.light,
            onSave: onSave,
            onCancel: { edit.cancel() }
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(shape.fill(Theme.TextColor.primary.with(opacity: 0.07)))
        .overlay {
            if draft.isRefused {
                shape.strokeBorder(Theme.Status.problem, lineWidth: 1.5)
            }
        }
        .accessibilityHint(draft.isRefused ? "A card needs a front" : "")
    }

    private func setTextHover(_ hovering: Bool) {
        guard hovering != isHoveringText else { return }
        isHoveringText = hovering
        if hovering { NSCursor.iBeam.push() } else { NSCursor.pop() }
    }

    private func click(_ showing: NowShowing?, onText: Bool) {
        switch PreviewClick.outcome(clickCount: PreviewClick.currentClickCount, onText: onText, hasCard: showing != nil) {
        case .flipAfterDoubleClickInterval:
            pendingFlip?.cancel()
            pendingFlip = Task {
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                guard !Task.isCancelled else { return }
                onFlip()
            }
        case .edit:
            if let showing { begin(showing) }
        case .ignore:
            break
        }
    }

    private func begin(_ showing: NowShowing, side: CardSide? = nil) {
        pendingFlip?.cancel()
        pendingFlip = nil
        if isHoveringText { setTextHover(false) }
        edit.begin(showing, side: side)
    }

    private func caption(_ showing: NowShowing?) -> some View {
        let isEditing = draft != nil
        return HStack(alignment: .firstTextBaseline) {
            if isEditing {
                Text("Return to save · Esc to cancel")
            } else if let showing {
                Text("Next card in \(showing.countdownText)")
                    .monospacedDigit()
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer(minLength: 8)
            // Hidden rather than removed while editing, so the row keeps its height.
            Button("Skip", action: onSkip)
                .buttonStyle(.capsuleSecondary)
                .disabled(showing == nil || isEditing)
                .opacity(isEditing ? 0 : 1)
                .accessibilityHidden(isEditing)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.TextColor.secondary)
    }
}

/// Cancel and Save, the height of the grade buttons they stand in for.
private struct EditButtons: View {
    var onCancel: () -> Void
    var onSave: () -> Void

    @Environment(\.accentChoice) private var accent

    var body: some View {
        HStack(spacing: 6) {
            button("Cancel", fill: Theme.TextColor.primary.with(opacity: 0.11), text: Theme.TextColor.primary, action: onCancel)
                .accessibilityHint("Keeps the card as it was")
            button("Save", fill: accent.fill, text: Theme.TextColor.onAccent, action: onSave)
                .accessibilityHint("Saves the change to this side")
        }
    }

    private func button(_ title: String, fill: Token, text: Token, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button(action: action) {
            Text(title)
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(text)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(shape.fill(fill))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

/// The card as one control for the keyboard and VoiceOver: Space or the default action flips it, Return
/// or the Edit card action edits the side showing, and a right-click offers both. While editing it steps
/// aside so the field inside can be reached.
private struct CardKeyboardAndAccessibility: ViewModifier {
    var isEditing: Bool
    var showing: NowShowing?
    var onFlip: () -> Void
    var onEdit: () -> Void

    func body(content: Content) -> some View {
        if isEditing {
            content.accessibilityElement(children: .contain)
        } else {
            content
                // Focusable by keyboard only (Tab, with Full Keyboard Access on), so a click doesn't ring it.
                .focusable(interactions: .activate)
                .onKeyPress(.return) {
                    guard showing != nil else { return .ignored }
                    onEdit()
                    return .handled
                }
                .onKeyPress(.space) {
                    onFlip()
                    return .handled
                }
                .contextMenu {
                    if let showing {
                        Button("Flip", action: onFlip)
                        Button(NowShowingPanel.editMenuTitle(isFlipped: showing.isFlipped), action: onEdit)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(NowShowingPanel.accessibilityHint(hasCard: showing != nil))
                .accessibilityAction { onFlip() }
                .modifier(EditAction(isAvailable: showing != nil, onEdit: onEdit))
        }
    }
}

/// Read as one label, like `CardFace`; while editing, the field inside is reached instead.
private struct FaceAccessibility: ViewModifier {
    var label: String?

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityElement(children: .ignore).accessibilityLabel(label)
        } else {
            content.accessibilityElement(children: .contain)
        }
    }
}

private struct EditAction: ViewModifier {
    var isAvailable: Bool
    var onEdit: () -> Void

    func body(content: Content) -> some View {
        if isAvailable {
            content.accessibilityAction(named: Text(NowShowingPanel.editActionName)) { onEdit() }
        } else {
            content
        }
    }
}

extension NowShowingPanel {
    /// The VoiceOver action, next to the flip, that edits the side showing.
    static let editActionName = "Edit card"

    static func accessibilityHint(hasCard: Bool) -> String {
        hasCard ? "Flips the card. Actions available." : "Flips the card"
    }

    /// The context menu edits the side you see, as double-click does.
    static func editMenuTitle(isFlipped: Bool) -> String { isFlipped ? "Edit Back" : "Edit Front" }
}

#if DEBUG
#Preview("Now showing") {
    HStack(alignment: .top, spacing: 24) {
        NowShowingPanel(
            deck: PreviewData.decks[0], state: PlaybackState(), onFlip: {}, onSkip: {}, studySummary: { _ in .sample }
        )
        NowShowingPanel(deck: Deck(name: "Empty"), state: PlaybackState(), onFlip: {}, onSkip: {})
    }
    .appearancePreview()
}

#Preview("Now showing, editing") {
    let deck = PreviewData.decks[0]
    let edit = PreviewCardEdit()
    if let showing = NowShowing.make(deck: deck, state: PlaybackState(), at: Date()) { edit.begin(showing) }
    return NowShowingPanel(deck: deck, state: PlaybackState(), onFlip: {}, onSkip: {}, studySummary: { _ in .sample }, edit: edit)
        .appearancePreview()
}
#endif

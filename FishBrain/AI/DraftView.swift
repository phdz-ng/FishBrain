import AppKit
import SwiftUI

/// The cards being made, and then reviewed: the name and the cards arrive one by one, can be edited as soon as
/// they are finished, and are saved only when the person says so.
struct DraftView: View {
    @ObservedObject var draft: GenerationDraft
    /// The deck the cards went into, to be selected.
    var onSaved: (Deck.ID) -> Void

    @EnvironmentObject private var composer: ComposerModel
    @EnvironmentObject private var store: DeckStore
    @EnvironmentObject private var ai: AIAccountStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accentChoice) private var accent
    @State private var isRenaming = false
    @State private var isPickingColor = false
    @State private var refineText = ""
    @State private var isConfirmingStartOver = false
    @State private var isConfirmingDiscard = false
    @FocusState private var focus: DraftField?

    enum DraftField: Hashable {
        case front(DraftCard.ID)
        case back(DraftCard.ID)
        case refine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nameBar
            statusLine
            if let problem = draft.problem {
                DraftBanner(
                    message: problem.message, fixes: problem.fixes, isProblem: true,
                    onFix: perform, onDismiss: { draft.dismissProblem() }
                )
            } else if let shortfall = draft.shortfall {
                DraftBanner(message: shortfall.text, fixes: [.addMore(shortfall.missing)], isProblem: false, onFix: perform, onDismiss: nil)
            }
            cardsPanel
            footer
        }
        .padding(.top, 38)
        .padding(.horizontal, 32)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The brief highlight on cards a refine or rewrite changed.
        .task(id: draft.changedIDs) {
            guard !draft.changedIDs.isEmpty else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { draft.clearChanged() }
        }
        // A key, or a model that has gone: the lists are out of date.
        .task(id: draft.problem) {
            if let problem = draft.problem, problem.error.needsModelListRefresh {
                await ai.refreshModels(for: draft.plan.provider.provider)
            }
        }
        .onChange(of: draft.phase) { _, phase in
            if phase == .review {
                announce("Finished. \(draft.cards.count) \(draft.cards.count == 1 ? "card" : "cards") to review.")
            }
        }
        .alert("Start over?", isPresented: $isConfirmingStartOver) {
            Button("Start Over", role: .destructive) { composer.startOver() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The cards you haven't saved are thrown away, and you go back to what you had added.")
        }
        .alert("Discard this draft?", isPresented: $isConfirmingDiscard) {
            Button("Discard", role: .destructive) { composer.discardDraft() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The cards you haven't saved are thrown away.")
        }
    }

    // MARK: Name

    private var nameBar: some View {
        HStack(alignment: .center, spacing: 12) {
            if draft.isNameFixed {
                // Cards for a deck that exists: its name and color are as they are.
                DeckIcon(color: draft.color, size: 30)
                Text(draft.displayName)
                    .font(Theme.Typography.title)
                    .tracking(-0.4)
                    .foregroundStyle(Theme.TextColor.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Text("adding to this deck")
                    .font(Theme.Typography.micro.weight(.medium))
                    .foregroundStyle(accent.light)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent.flippedSurface))
                    .fixedSize()
            } else {
                Button { isPickingColor = true } label: { DeckIcon(color: draft.color, size: 30) }
                    .buttonStyle(.plain)
                    .help("Change deck color")
                    .accessibilityLabel("Deck color, \(draft.color.displayName)")
                    .popover(isPresented: $isPickingColor, arrowEdge: .bottom) {
                        DeckColorPicker(selection: draft.color) { color in
                            draft.setColor(color)
                            isPickingColor = false
                        }
                    }
                if draft.name.isEmpty && draft.phase == .generating {
                    Text("Naming your deck…")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.TextColor.secondary)
                        .lineLimit(1)
                } else {
                    // The name gives way (and is cut short) before the tag and the buttons do.
                    EditableTitle(text: draft.displayName, isEditing: $isRenaming) { draft.rename($0) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if draft.isNameSuggested {
                    Text("suggested name")
                        .font(Theme.Typography.micro.weight(.medium))
                        .foregroundStyle(accent.light)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(accent.flippedSurface))
                        .fixedSize()
                }
            }
            Spacer(minLength: 4)
            if draft.isBusy {
                Button { draft.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.capsuleSecondary)
                    .fixedSize()
                    .help("Stop and keep the cards that are finished")
            } else {
                if let source = sourceLabel {
                    Text(source)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Start over") { draft.cards.isEmpty ? composer.startOver() : (isConfirmingStartOver = true) }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(accent.light)
                    .help("Go back to what you added, and throw this draft away")
                Button("Discard") { draft.cards.isEmpty ? composer.discardDraft() : (isConfirmingDiscard = true) }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .help("Throw this draft away")
            }
        }
    }

    /// "from Campbell Biology – Ch. 9.pdf", or "from 3 files".
    private var sourceLabel: String? {
        let names = draft.snapshot.items.map(\.name)
        switch names.count {
        case 0: return nil
        case 1: return "from \(names[0])"
        default: return "from \(names.count) files"
        }
    }

    // MARK: Progress

    @ViewBuilder
    private var statusLine: some View {
        switch draft.activeOperation {
        case .generate, .addMore:
            HStack(spacing: 12) {
                Text(draft.progressText)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.cardBack)
                    .monospacedDigit()
                ProgressBar(value: draft.progress)
                    .frame(maxWidth: .infinity)
                Text(draft.modelName)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(draft.progressText)
        case .refine:
            busyLine("Changing the cards…")
        case .rewrite:
            busyLine("Writing a new card…")
        case nil:
            EmptyView()
        }
    }

    private func busyLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.cardBack)
        }
    }

    // MARK: Cards

    private var cardsPanel: some View {
        GlassPanel {
            VStack(spacing: 0) {
                header
                HairlineDivider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(draft.cards) { card in
                                DraftRow(
                                    card: card,
                                    draft: draft,
                                    focus: $focus,
                                    index: (draft.cards.firstIndex(of: card) ?? 0) + 1,
                                    isChanged: draft.changedIDs.contains(card.id),
                                    isRewriting: draft.activeOperation == .rewrite(card.id),
                                    canRewrite: draft.phase == .review && !draft.isBusy
                                )
                                .id(card.id)
                                .transition(.opacity)
                            }
                            ForEach(0..<draft.skeletonCount, id: \.self) { _ in SkeletonRow() }
                            Button { draft.addCardYourself() } label: {
                                Label("Add a card yourself", systemImage: "plus")
                                    .font(Theme.Typography.rowTitle)
                                    .foregroundStyle(accent.light)
                                    .padding(.horizontal, 18)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: draft.cards.count)
                    }
                    .onChange(of: draft.focusRequest) { _, id in
                        guard let id else { return }
                        draft.focusRequest = nil
                        DispatchQueue.main.async {
                            proxy.scrollTo(id)
                            focus = .front(id)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { draft.toggleAll() } label: { CheckMark(state: draft.selection) }
                .buttonStyle(.plain)
                .disabled(draft.cards.isEmpty)
                .accessibilityLabel(draft.selection == .all ? "Clear all cards" : "Select all cards")
                .accessibilityValue(draft.selection == .all ? "All selected" : draft.selection == .some ? "Some selected" : "None selected")
            Text("Front").frame(maxWidth: .infinity, alignment: .leading)
            Text("Back").frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: DraftRow.metaWidth)
        }
        .font(Theme.Typography.footnote.weight(.semibold))
        .foregroundStyle(Theme.TextColor.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                refineField
                Text(draft.selectedText)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .monospacedDigit()
                addToDeckMenu
                saveButton
            }
            if let cost = draft.costText {
                Text(cost)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .help(AIPricing.tooltip())
            }
        }
    }

    private var canRefine: Bool { draft.phase == .review && !draft.isBusy && !draft.cards.isEmpty }

    private var refineField: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(Theme.Typography.footnote)
                .foregroundStyle(accent.light)
                .accessibilityHidden(true)
            TextField("Refine all cards: “make the answers shorter”", text: $refineText)
                .textFieldStyle(.plain)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.primary)
                .focused($focus, equals: .refine)
                .onSubmit(refine)
                .accessibilityLabel("Refine all cards")
                .accessibilityHint("Say what to change, for example make the answers shorter, then press Return")
            Button(action: refine) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(refineText.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.TextColor.secondary : accent.fill)
            }
            .buttonStyle(.plain)
            .disabled(!canRefine || refineText.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Refine")
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(minHeight: 32)
        .background(Capsule().fill(Theme.Surface.control))
        .frame(maxWidth: .infinity)
        .opacity(canRefine ? 1 : 0.5)
        .disabled(!canRefine)
    }

    /// The deck the cards were asked to go into, when it is still there.
    private var fixedDeck: Deck? {
        guard let target = draft.targetDeck else { return nil }
        return store.decks.first { $0.id == target.id }
    }

    private var addToDeckMenu: some View {
        Menu {
            ForEach(store.decks.filter { $0.id != fixedDeck?.id }) { deck in
                Button(deck.name) { save(to: deck.id) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(fixedDeck == nil ? "Add to deck" : "Add to another deck")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(Theme.Typography.caption.weight(.medium))
            .foregroundStyle(Theme.TextColor.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Capsule().fill(Theme.Surface.control))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!draft.canSave || otherDecksCount == 0)
        .opacity(draft.canSave && otherDecksCount > 0 ? 1 : 0.5)
        .accessibilityLabel("Add the selected cards to an existing deck")
    }

    private var otherDecksCount: Int { store.decks.filter { $0.id != fixedDeck?.id }.count }

    /// "Add to “Spanish A2”" when the cards were made for that deck, else "Save as new deck".
    private var saveButton: some View {
        Button(fixedDeck.map { "Add to “\($0.name)”" } ?? "Save as new deck") {
            let id = fixedDeck == nil ? draft.saveAsNewDeck(in: store) : draft.saveToTargetDeck(in: store)
            if let id { onSaved(id) }
        }
        .buttonStyle(.capsulePrimary)
        .disabled(!draft.canSave)
        .opacity(draft.canSave ? 1 : 0.5)
        .keyboardShortcut(.return, modifiers: .command)
        .help(draft.canSave ? "" : "Tick at least one card, and wait for the cards to finish.")
    }

    // MARK: Actions

    private func refine() {
        let text = refineText
        guard canRefine, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        refineText = ""
        draft.refine(text)
    }

    private func save(to deckID: Deck.ID) {
        if let id = draft.save(to: deckID, in: store) { onSaved(id) }
    }

    private func perform(_ fix: DraftFix) {
        switch fix {
        case .openSettings:
            SettingsNavigator.shared.tab = .ai
            openSettings()
        case .tryAgain: draft.retry()
        case .addMore(let count):
            draft.dismissProblem()
            draft.addMore(count)
        case .startOver: composer.startOver()
        }
    }

    private func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}

// MARK: - Pieces

/// The inline banner: one message and what to do about it.
private struct DraftBanner: View {
    var message: String
    var fixes: [DraftFix]
    var isProblem: Bool
    var onFix: (DraftFix) -> Void
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isProblem ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(isProblem ? Theme.Status.problem : Theme.TextColor.cardBack)
                .accessibilityHidden(true)
            Text(message)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            ForEach(fixes, id: \.self) { fix in
                Button(title(of: fix)) { onFix(fix) }
                    .buttonStyle(.capsuleSecondary)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.TextColor.onControl)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isProblem ? Theme.Status.problem.with(opacity: 0.14) : Theme.TextColor.primary.with(opacity: 0.07)))
        .accessibilityElement(children: .contain)
    }

    private func title(of fix: DraftFix) -> String {
        switch fix {
        case .openSettings: "Open Settings"
        case .tryAgain: "Try again"
        case .addMore(let count): "Add \(count) more"
        case .startOver: "Start over"
        }
    }
}

/// A checkbox that can also read "some": for the header and each card.
private struct CheckMark: View {
    var state: DraftSelection

    @Environment(\.accentChoice) private var accent

    var body: some View {
        Image(systemName: state == .all ? "checkmark.square.fill" : state == .some ? "minus.square.fill" : "square")
            .font(.system(size: 16))
            .foregroundStyle(state == .none ? Theme.TextColor.secondary : accent.fill)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}

/// A thin bar that fills as the cards arrive.
private struct ProgressBar: View {
    var value: Double

    @Environment(\.accentChoice) private var accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Surface.progressTrack)
                Capsule().fill(accent.light).frame(width: proxy.size.width * value)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// A card to come.
private struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 14) {
            CheckMark(state: .none).opacity(0.4)
            RoundedRectangle(cornerRadius: 6).fill(Theme.Surface.progressTrack).frame(height: 12).frame(maxWidth: .infinity)
            RoundedRectangle(cornerRadius: 6).fill(Theme.Surface.progressTrack).frame(height: 12).frame(maxWidth: .infinity)
            Spacer().frame(width: DraftRow.metaWidth)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { HairlineDivider() }
        .accessibilityHidden(true)
    }
}

/// One card: a checkbox, the front and back to edit in place, and its page, ↻ and "added".
private struct DraftRow: View {
    static let metaWidth: CGFloat = 92

    var card: DraftCard
    @ObservedObject var draft: GenerationDraft
    var focus: FocusState<DraftView.DraftField?>.Binding
    var index: Int
    var isChanged: Bool
    var isRewriting: Bool
    var canRewrite: Bool

    @Environment(\.accentChoice) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button { draft.toggle(card.id) } label: { CheckMark(state: card.isSelected ? .all : .none) }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .accessibilityLabel("Include card \(index)")
                .accessibilityValue(card.isSelected ? "Included" : "Not included")
            TextField("Front", text: Binding(get: { card.front }, set: { draft.setFront(card.id, $0) }), axis: .vertical)
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.TextColor.primary)
                .focused(focus, equals: .front(card.id))
                .onSubmit { focus.wrappedValue = .back(card.id) }
                .accessibilityLabel("Front of card \(index)")
            TextField("Back", text: Binding(get: { card.back }, set: { draft.setBack(card.id, $0) }), axis: .vertical)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.TextColor.cardBack)
                .focused(focus, equals: .back(card.id))
                .accessibilityLabel("Back of card \(index)")
            meta
        }
        .textFieldStyle(.plain)
        .opacity(card.isSelected ? 1 : 0.45)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background {
            if isChanged {
                Rectangle().fill(accent.fill.with(opacity: 0.22))
            } else if card.isAdded {
                Rectangle().fill(Theme.Status.ok.with(opacity: 0.07))
            }
        }
        .overlay(alignment: .top) { HairlineDivider() }
        .animation(.easeOut(duration: 0.4), value: isChanged)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            if card.isAdded {
                Text("added")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Status.ok)
            }
            if let page = card.sourcePage {
                Text("p. \(page)")
                    .font(Theme.Typography.micro)
                    .monospacedDigit()
                    .foregroundStyle(Theme.TextColor.cardBack)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.TextColor.primary.with(opacity: 0.08)))
                    .accessibilityLabel("Page \(page)")
            }
            Group {
                if isRewriting {
                    ProgressView().controlSize(.small)
                } else {
                    Button { draft.rewrite(card.id) } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.TextColor.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRewrite)
                    .opacity(canRewrite ? 1 : 0.35)
                    .help("Write a new card to replace this one")
                    .accessibilityLabel("Rewrite card \(index)")
                }
            }
        }
        .frame(width: Self.metaWidth, alignment: .trailing)
    }
}

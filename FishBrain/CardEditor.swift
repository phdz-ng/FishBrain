import SwiftUI

/// The deck's cards as an editable grouped list: Front, Back and Status columns, inline editing,
/// drag to reorder, hover delete, and the card that is live right now highlighted.
struct CardEditor: View {
    static let statusColumnWidth: CGFloat = 124

    /// How a row is laid out, by the width of the list.
    enum RowLayout: Equatable {
        /// Front, Back and Status side by side.
        case columns
        /// Front and Back side by side, the Status chip under them.
        case chipBelow
        /// Front over Back over the chip: the narrowest the window goes.
        case stacked

        static let columnsMinimumWidth: CGFloat = 520
        static let chipBelowMinimumWidth: CGFloat = 400

        init(width: CGFloat) {
            self = width >= Self.columnsMinimumWidth ? .columns : width >= Self.chipBelowMinimumWidth ? .chipBelow : .stacked
        }
    }

    var deck: Deck
    /// Set by whoever adds a card; the editor scrolls to it and focuses its Front field.
    @Binding var focusRequest: Card.ID?
    /// A card picked from the search results: scrolled into view and strongly highlighted.
    var highlightedCardID: Card.ID?
    var onAddCard: () -> Void
    var onPasteCards: (() -> Void)?
    var onImportCSV: (() -> Void)?

    enum Field: Hashable {
        case front(Card.ID)
        case back(Card.ID)
    }

    @EnvironmentObject private var store: DeckStore
    @EnvironmentObject private var playback: PlaybackStore
    @Environment(\.accentChoice) private var accent
    @FocusState private var focus: Field?
    @State private var selection = Set<Card.ID>()
    @State private var now = Date()
    private let scheduler = CardScheduler()

    var body: some View {
        GlassPanel {
            if deck.cards.isEmpty {
                EmptyCardsState(onAddCard: onAddCard, onPasteCards: onPasteCards, onImportCSV: onImportCSV)
            } else {
                GeometryReader { geometry in
                    list(layout: RowLayout(width: geometry.size.width))
                }
            }
        }
    }

    private var liveCardID: Card.ID? {
        scheduler.currentCard(in: deck, state: playback.state(for: deck.id), at: now)?.card.id
    }

    private func list(layout: RowLayout) -> some View {
        let state = playback.state(for: deck.id)
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    if layout == .stacked {
                        Text("Cards").frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Front").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Back").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if layout == .columns {
                        Text("Status").frame(width: Self.statusColumnWidth, alignment: .leading)
                    }
                }
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.TextColor.secondary)
                .padding(.leading, 38)
                .padding(.trailing, layout == .columns ? 56 : 44)
                .padding(.vertical, 10)
                HairlineDivider()
                List(selection: $selection) {
                    ForEach(deck.cards) { card in
                        CardRow(
                            front: binding(card.id, \.front),
                            back: binding(card.id, \.back),
                            frontImage: card.frontImage,
                            backImage: card.backImage,
                            status: CardStatus(state.review(for: card.id), at: now),
                            layout: layout,
                            cardID: card.id,
                            deckID: deck.id,
                            focus: $focus,
                            onDelete: { delete([card.id]) },
                            onSubmitBack: { submitBack(of: card.id) }
                        )
                        .id(card.id)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(rowBackground(for: card.id))
                    }
                    .onMove { store.moveCards(in: deck.id, from: $0, to: $1) }

                    Button(action: onAddCard) {
                        Label("Add Card", systemImage: "plus")
                            .font(Theme.Typography.body)
                            .foregroundStyle(accent.light)
                            .padding(.horizontal, 18)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onDeleteCommand { delete(selection) }
                // Paste Picture (Shift-Command-V) works on the side being edited.
                .onChange(of: focus, initial: true) { _, field in
                    CommandCenter.shared.pastePicture = field.map { field in
                        { pastePicture(for: field) }
                    }
                }
                .onDisappear { CommandCenter.shared.pastePicture = nil }
                .onChange(of: highlightedCardID, initial: true) { _, id in
                    guard let id else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: focusRequest) { _, id in
                    guard let id else { return }
                    focusRequest = nil
                    // The new row needs a moment to exist before it can take focus.
                    DispatchQueue.main.async {
                        proxy.scrollTo(id)
                        focus = .front(id)
                    }
                }
            }
        }
        // Rolls the highlight forward at each rotation boundary, and keeps the status chips ("Due now",
        // "Learning · 9 min") from going stale in between.
        .task {
            while !Task.isCancelled {
                now = Date()
                let next = scheduler.nextRotation(after: now)
                let wait = min(max(next.timeIntervalSinceNow, 0) + 0.05, 30)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    @ViewBuilder
    private func rowBackground(for id: Card.ID) -> some View {
        if id == highlightedCardID {
            Rectangle().fill(accent.fill.with(opacity: 0.34))
        } else if id == liveCardID {
            Rectangle().fill(accent.fill.with(opacity: 0.16))
        } else {
            EmptyView()
        }
    }

    private func binding(_ id: Card.ID, _ keyPath: WritableKeyPath<Card, String>) -> Binding<String> {
        Binding(
            get: { store.card(id, in: deck.id)?[keyPath: keyPath] ?? "" },
            set: { newValue in store.updateCard(id, in: deck.id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func delete(_ ids: Set<Card.ID>) {
        guard !ids.isEmpty else { return }
        selection.subtract(ids)
        store.deleteCards(ids, in: deck.id)
    }

    private func pastePicture(for field: Field) {
        guard let source = PicturePasteboard.read() else { return }
        let (side, id): (CardSide, Card.ID) = switch field {
        case .front(let id): (.front, id)
        case .back(let id): (.back, id)
        }
        Task { try? await store.addImage(source, on: side, for: id, in: deck.id) }
    }

    /// Return in the Back field of the last card keeps the flow going with a fresh card.
    private func submitBack(of id: Card.ID) {
        if deck.cards.last?.id == id { onAddCard() }
    }
}

private struct CardRow: View {
    @Binding var front: String
    @Binding var back: String
    var frontImage: CardImage?
    var backImage: CardImage?
    var status: CardStatus
    var layout: CardEditor.RowLayout
    var cardID: Card.ID
    var deckID: Deck.ID
    var focus: FocusState<CardEditor.Field?>.Binding
    var onDelete: () -> Void
    var onSubmitBack: () -> Void

    @State private var isHovering = false

    private var frontField: some View {
        CardSideField(
            side: .front, text: $front, image: frontImage, cardID: cardID, deckID: deckID,
            focus: focus, showsAddPicture: isHovering, onSubmit: { focus.wrappedValue = .back(cardID) }
        )
    }

    private var backField: some View {
        CardSideField(
            side: .back, text: $back, image: backImage, cardID: cardID, deckID: deckID,
            focus: focus, showsAddPicture: isHovering, onSubmit: onSubmitBack
        )
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "line.3.horizontal")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
                .opacity(isHovering ? 1 : 0)
                .frame(width: 6)
                .accessibilityHidden(true)
            switch layout {
            case .columns:
                frontField
                backField
                CardStatusChip(status: status)
                    .frame(width: CardEditor.statusColumnWidth, alignment: .leading)
            case .chipBelow:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 16) {
                        frontField
                        backField
                    }
                    CardStatusChip(status: status).padding(.leading, 4)
                }
                .padding(.vertical, 6)
            case .stacked:
                VStack(alignment: .leading, spacing: 2) {
                    frontField
                    backField
                    CardStatusChip(status: status).padding(.leading, 4).padding(.top, 2)
                }
                .padding(.vertical, 6)
            }
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .accessibilityLabel("Delete card")
        }
        .textFieldStyle(.plain)
        .lineLimit(1...4)
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { HairlineDivider() }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { Button("Delete Card", role: .destructive, action: onDelete) }
    }
}

/// One side of a card in the editor: its text, and its picture (a small thumbnail, or a button to add
/// one). A picture file dropped on the side is added to it.
private struct CardSideField: View {
    var side: CardSide
    @Binding var text: String
    var image: CardImage?
    var cardID: Card.ID
    var deckID: Deck.ID
    var focus: FocusState<CardEditor.Field?>.Binding
    var showsAddPicture: Bool
    var onSubmit: () -> Void

    @EnvironmentObject private var store: DeckStore
    @State private var isDropTarget = false
    @State private var failure: String?

    private var label: String { side == .front ? "Front" : "Back" }

    var body: some View {
        HStack(spacing: 8) {
            TextField(label, text: $text, axis: .vertical)
                .font(side == .front ? Theme.Typography.body.weight(.semibold) : Theme.Typography.body)
                .foregroundStyle(side == .front ? Theme.TextColor.primary : Theme.TextColor.cardBack)
                .focused(focus, equals: side == .front ? .front(cardID) : .back(cardID))
                .onSubmit(onSubmit)
                .accessibilityLabel(label)
            PictureControl(side: side, image: image, cardID: cardID, deckID: deckID, showsAdd: showsAddPicture, failure: $failure)
        }
        .padding(.horizontal, 4)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.TextColor.primary.with(opacity: 0.12))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: PictureSource.isPicture) else {
                failure = "That isn't a picture FishBrain can read."
                return false
            }
            Task {
                do { try await store.addImage(contentsOf: url, on: side, for: cardID, in: deckID) } catch {
                    failure = "That file couldn't be read as a picture."
                }
            }
            return true
        } isTargeted: { isDropTarget = $0 }
        .alert("Couldn't add the picture", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }
}

/// The picture on a side: a thumbnail you can click for its description and to replace or remove it, or,
/// while the row is hovered, a button to add one (from a file, or from the clipboard).
private struct PictureControl: View {
    var side: CardSide
    var image: CardImage?
    var cardID: Card.ID
    var deckID: Deck.ID
    var showsAdd: Bool
    @Binding var failure: String?

    @EnvironmentObject private var store: DeckStore
    @State private var isChoosing = false
    @State private var isShowingDetails = false

    private var sideName: String { side == .front ? "front" : "back" }

    var body: some View {
        Group {
            if let image {
                Button { isShowingDetails.toggle() } label: {
                    CardPicture(image: image, thumbnail: true, store: store.imageStore)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Picture on the \(sideName)")
                .accessibilityHint("Edits its description, replaces it or removes it")
                .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
                    PictureDetails(side: side, image: image, cardID: cardID, deckID: deckID, onReplace: { isChoosing = true })
                }
            } else {
                Menu {
                    Button("Choose Picture…") { isChoosing = true }
                    Button("Paste Picture") { paste() }
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.TextColor.secondary)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(showsAdd ? 1 : 0)
                .accessibilityLabel("Add a picture to the \(sideName)")
            }
        }
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            attach(.file(url))
        }
    }

    private func paste() {
        guard let source = PicturePasteboard.read() else {
            failure = "There is no picture on the clipboard."
            return
        }
        attach(source)
    }

    private func attach(_ source: PictureSource) {
        Task {
            do { try await store.addImage(source, on: side, for: cardID, in: deckID) } catch {
                failure = "That couldn't be read as a picture."
            }
        }
    }
}

/// A picture's details: what VoiceOver says for it, and replacing or removing it.
private struct PictureDetails: View {
    var side: CardSide
    var image: CardImage
    var cardID: Card.ID
    var deckID: Deck.ID
    var onReplace: () -> Void

    @EnvironmentObject private var store: DeckStore
    @State private var description = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardPicture(image: image, thumbnail: false, store: store.imageStore)
                .frame(width: 240, height: 170)
            TextField("Description for VoiceOver", text: $description, prompt: Text("Defaults to this side's text"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: description) { _, text in
                    store.setAltText(text, on: side, for: cardID, in: deckID)
                }
                .accessibilityLabel("Description for VoiceOver")
            HStack {
                Button("Replace…", action: onReplace)
                Spacer()
                Button("Remove", role: .destructive) {
                    store.setImage(nil, on: side, for: cardID, in: deckID)
                }
            }
        }
        .padding(16)
        .frame(width: 272)
        .onAppear { description = image.altText ?? "" }
    }
}

private struct EmptyCardsState: View {
    var onAddCard: () -> Void
    var onPasteCards: (() -> Void)?
    var onImportCSV: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            StackGlyph()
                .stroke(Theme.TextColor.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            Text("No cards yet")
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.TextColor.primary)
            Text("Add cards one at a time, paste a list, or import a file.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.TextColor.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Add Card", action: onAddCard).buttonStyle(.capsulePrimary)
                Button("Paste Cards") { onPasteCards?() }
                    .buttonStyle(.capsuleSecondary)
                    .disabled(onPasteCards == nil)
                Button("Import…") { onImportCSV?() }
                    .buttonStyle(.capsuleSecondary)
                    .disabled(onImportCSV == nil)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

#if DEBUG
#Preview("Card editor") {
    CardEditor(deck: PreviewData.decks[0], focusRequest: .constant(nil), onAddCard: {})
        .environmentObject(PreviewData.store())
        .environmentObject(PreviewData.playback())
        .frame(width: 640, height: 360)
        .padding(24)
        .background(Theme.Surface.previewBackdrop)
        .preferredColorScheme(.dark)
}

#Preview("Card editor, empty") {
    CardEditor(deck: Deck(name: "Empty"), focusRequest: .constant(nil), onAddCard: {})
        .environmentObject(PreviewData.store())
        .environmentObject(PreviewData.playback())
        .frame(width: 640, height: 300)
        .padding(24)
        .background(Theme.Surface.previewBackdrop)
        .preferredColorScheme(.dark)
}
#endif

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The "Create with AI" row above the deck list: a sparkle icon in the accent, filled when selected.
struct CreateWithAIRow: View {
    var isSelected: Bool
    /// "9/20" while cards are arriving, "Draft" once they have, nothing without a draft.
    var badge: String?

    @Environment(\.accentChoice) private var accent

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Theme.Surface.onAccentIcon : accent.fill)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.TextColor.primary)
                }
                .accessibilityHidden(true)
            Text("Create with AI")
                .font(Theme.Typography.rowTitle.weight(isSelected ? .medium : .regular))
                .foregroundStyle(Theme.TextColor.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let badge {
                Text(badge)
                    .font(Theme.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Theme.TextColor.primary : Theme.TextColor.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.fill)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.map { "Create with AI, \($0)" } ?? "Create with AI")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Create with AI: one screen to add material, say what matters, and start a run.
struct ComposerView: View {
    @EnvironmentObject private var model: ComposerModel
    @EnvironmentObject private var store: DeckStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var ai: AIAccountStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accentChoice) private var accent
    @State private var isTargeted = false
    @State private var isChoosingFiles = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case sources, focus }

    static let focusPlaceholder = "e.g. Focus on the steps of glycolysis and the ATP counts. Skip the history."

    var body: some View {
        // The form scrolls; Generate stays in view underneath it.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    sourceArea
                    focusField
                    options
                }
                .padding(.top, 38)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            generateRow
                .padding(.horizontal, 32)
                .padding(.top, 4)
                .padding(.bottom, 20)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The cost is asked for a moment after the last change, not on every keystroke.
        .task(id: model.costKey(decks: store.decks)) {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await model.refreshCost(decks: store.decks)
        }
        .onAppear {
            focused = .sources
            ai.refreshOnDevice() // Apple Intelligence may have been turned on since
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in ai.refreshOnDevice() }
        .fileImporter(
            isPresented: $isChoosingFiles,
            allowedContentTypes: Self.choosableTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { Task { await model.addFiles(urls) } }
        }
    }

    static let choosableTypes: [UTType] = [.pdf, .image, .plainText, .text, .commaSeparatedText]
        + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Create with AI")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.TextColor.primary)
                .accessibilityAddTraits(.isHeader)
            Text("Turn a document, a picture or your notes into a deck you can edit.")
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.TextColor.secondary)
        }
    }

    // MARK: Sources

    private var sourceArea: some View {
        let problems = model.problems
        return VStack(alignment: .leading, spacing: 12) {
            if !model.items.isEmpty || model.readingCount > 0 {
                WrapLayout(spacing: 10) {
                    ForEach(model.items) { item in
                        SourceChip(item: item, problem: problems[item.id], limit: model.maxPDFPages)
                    }
                    if model.readingCount > 0 {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading…")
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.TextColor.secondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 48)
                    }
                }
            }
            ForEach(model.notices) { notice in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Status.problem)
                        .accessibilityHidden(true)
                    Text(notice.text)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.cardBack)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("OK") { model.dismissNotice(notice.id) }
                        .buttonStyle(.plain)
                        .font(Theme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(Theme.TextColor.primary)
                }
            }
            if let note = model.onDeviceNote {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.TextColor.cardBack)
                        .accessibilityHidden(true)
                    Text(note)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.cardBack)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            dropHint
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                .fill(accent.fill.with(opacity: isTargeted ? 0.18 : 0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                .strokeBorder(
                    accent.light.with(opacity: isTargeted || focused == .sources ? 0.9 : 0.45),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        }
        .focusable()
        .focused($focused, equals: .sources)
        .focusEffectDisabled()
        .onDrop(of: [.fileURL, .image, .plainText], isTargeted: $isTargeted) { providers in
            receive(providers)
            return true
        }
        // ⌘V with the sources area (not the text field) selected: files, a picture or text.
        .onPasteCommand(of: [.fileURL, .image, .plainText]) { providers in receive(providers) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources")
    }

    private var dropHint: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(accent.light)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop PDFs, pictures or text files")
                    .font(Theme.Typography.rowTitle.weight(.semibold))
                    .foregroundStyle(Theme.TextColor.primary)
                Text("or paste with ⌘V")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.cardBack)
            }
            Spacer(minLength: 8)
            Button("Choose Files…") { isChoosingFiles = true }
                .buttonStyle(.capsuleSecondary)
            Button("Paste") { Task { await model.addFromPasteboard() } }
                .buttonStyle(.capsuleSecondary)
                .help("Add what is on the clipboard: files, a picture or text")
                .accessibilityLabel("Paste from the clipboard")
        }
    }

    private func receive(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            let incoming = await IncomingSource.load(from: providers)
            await model.add(incoming)
        }
    }

    // MARK: What matters

    private var focusField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("What matters to you")
                .font(Theme.Typography.sectionLabel)
                .foregroundStyle(Theme.TextColor.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.focus)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.TextColor.primary)
                    .scrollContentBackground(.hidden)
                    .focused($focused, equals: .focus)
                    .frame(minHeight: 84)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .accessibilityLabel("What matters to you")
                if model.focus.isEmpty {
                    Text(Self.focusPlaceholder)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.TextColor.onControl)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.Surface.control))
        }
    }

    // MARK: Options

    private var options: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 18) {
            GridRow {
                option("How many cards") { countPicker }
                option("Card style") { stylePicker }
            }
            GridRow {
                option("Card language") { languagePicker }
                option("Put cards in") { destinationPicker }
            }
        }
    }

    private func option<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Theme.Typography.sectionLabel)
                .foregroundStyle(Theme.TextColor.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridColumnAlignment(.leading)
    }

    private var countPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(ComposerModel.presetCounts, id: \.self) { count in
                    SegmentButton(title: "\(count)", label: "\(count) cards", isSelected: !model.isCustomCount && model.cardCount == count) {
                        model.choosePreset(count)
                    }
                }
                SegmentButton(title: "Custom", label: "Custom number of cards", isSelected: model.isCustomCount) {
                    model.chooseCustom()
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.Surface.control))
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("How many cards")
            if model.isCustomCount {
                Stepper(
                    value: Binding(get: { model.cardCount }, set: { model.cardCount = $0 }),
                    in: ComposerModel.countRange
                ) {
                    Text("\(model.cardCount) \(model.cardCount == 1 ? "card" : "cards")")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.TextColor.primary)
                }
                .fixedSize()
                .accessibilityLabel("Number of cards")
            }
        }
    }

    private var stylePicker: some View {
        WrapLayout(spacing: 6) {
            ForEach(CardStyle.allCases) { style in
                ChoiceChip(title: style.displayName, isSelected: model.style == style) { model.style = style }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Card style")
    }

    private var languagePicker: some View {
        Picker("Card language", selection: $model.languageName) {
            Text("Same as source").tag(String?.none)
            ForEach(ComposerModel.languages, id: \.self) { Text($0).tag(String?.some($0)) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var destinationPicker: some View {
        Picker(
            "Put cards in",
            selection: Binding(
                get: { model.resolvedDestination(in: store.decks) },
                set: { model.destination = $0 }
            )
        ) {
            Text("A new deck (FishBrain names it)").tag(ComposerDestination.newDeck)
            ForEach(store.decks) { Text($0.name).tag(ComposerDestination.deck($0.id)) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    // MARK: Generate

    private var generateRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HairlineDivider()
            if model.readiness == .needsProvider {
                setUpRow
            } else {
                providerRow
            }
            if model.readiness == .modelCantMakeCards {
                Text(GenerationError.modelCantMakeCards.message)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Status.problem)
            }
        }
    }

    private var setUpRow: some View {
        HStack(spacing: 14) {
            Text("Set up an AI provider to start")
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.TextColor.cardBack)
            Spacer(minLength: 8)
            Button("Open Settings → AI", action: openAISettings)
                .buttonStyle(.capsulePrimary)
        }
    }

    private var providerRow: some View {
        HStack(spacing: 14) {
            if let active = model.activeProvider {
                Group {
                    if active.provider.isOnDevice {
                        Image(systemName: "desktopcomputer").font(Theme.Typography.footnote)
                    } else {
                        Text(String(active.provider.displayName.prefix(1))).font(Theme.Typography.footnote.weight(.bold))
                    }
                }
                .foregroundStyle(Theme.TextColor.primary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.Surface.control))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(active.summary)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.TextColor.primary)
                        Button("Change…", action: openAISettings)
                            .buttonStyle(.plain)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(accent.light)
                            .accessibilityLabel("Change the provider or model in Settings")
                    }
                    costLine
                }
            }
            Spacer(minLength: 8)
            Button(action: generate) {
                Label("Generate \(model.cardCount) \(model.cardCount == 1 ? "card" : "cards")", systemImage: "sparkles")
            }
            .buttonStyle(.capsulePrimary)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canGenerate)
            .opacity(model.canGenerate ? 1 : 0.5)
            .help(model.canGenerate ? "" : disabledReason)
        }
    }

    @ViewBuilder
    private var costLine: some View {
        switch model.cost {
        case .hidden:
            EmptyView()
        case .calculating:
            Text("Estimating the cost…")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
        case .estimate(let estimate):
            Text(estimate.line())
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
                .help(AIPricing.tooltip())
        }
    }

    private var disabledReason: String {
        switch model.readiness {
        case .needsInput: "Add a file, paste some text, or say what matters first."
        case .hasProblems: "Fix what is marked above first."
        case .modelCantMakeCards: GenerationError.modelCantMakeCards.message
        case .needsProvider, .ready: ""
        }
    }

    private func generate() {
        model.startRun(decks: store.decks)
    }

    private func openAISettings() {
        SettingsNavigator.shared.tab = .ai
        openSettings()
    }
}

// MARK: - Pieces

/// One thing added: a picture or icon, its name, how big it is, and a way to take it out. When something is
/// wrong with it, the reason is said right under it.
private struct SourceChip: View {
    var item: ComposerItem
    var problem: ComposerProblem?
    var limit: Int

    @EnvironmentObject private var model: ComposerModel
    @State private var isChoosingPages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chip
            if let problem {
                Text(problem.message)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Status.problem)
                    .fixedSize(horizontal: false, vertical: true)
                if problem.offersPageRange {
                    Button("Choose pages…") { isChoosingPages = true }
                        .buttonStyle(.capsuleSecondary)
                }
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .popover(isPresented: $isChoosingPages, arrowEdge: .bottom) { pagePicker }
    }

    private var chip: some View {
        HStack(spacing: 9) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(Theme.Typography.footnote.weight(.medium))
                    .foregroundStyle(Theme.TextColor.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.TextColor.cardBack)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.remove(item.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.TextColor.onControl)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel("Remove \(item.name)")
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.TextColor.primary.with(opacity: 0.08)))
        .overlay {
            if problem != nil {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.Status.problem, lineWidth: 1)
            }
        }
        .contextMenu {
            if item.kind == .pdf {
                Button("Choose Pages…") { isChoosingPages = true }
                if item.pageRange != nil {
                    Button("Use All Pages") { Task { await model.setPages(nil, for: item.id) } }
                }
                Divider()
            }
            Button("Remove") { model.remove(item.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.accessibilityText)
    }

    @ViewBuilder
    private var leading: some View {
        if let data = item.thumbnail, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: item.kind == .pdf ? "doc.richtext" : "doc.text")
                .font(.system(size: 18))
                .foregroundStyle(Theme.TextColor.cardBack)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var pagePicker: some View {
        if let full = item.fullPDF {
            PageRangePicker(
                pageCount: full.originalPageCount ?? full.pageCount,
                limit: limit,
                current: item.pageRange
            ) { range in
                isChoosingPages = false
                Task { await model.setPages(range, for: item.id) }
            }
        }
    }
}

/// Which pages of a PDF to send, for one that is too long (or when only a chapter is wanted).
struct PageRangePicker: View {
    var pageCount: Int
    var limit: Int
    var current: ClosedRange<Int>?
    var onApply: (ClosedRange<Int>?) -> Void

    @State private var from: Int
    @State private var to: Int

    init(pageCount: Int, limit: Int, current: ClosedRange<Int>?, onApply: @escaping (ClosedRange<Int>?) -> Void) {
        self.pageCount = pageCount
        self.limit = limit
        self.current = current
        self.onApply = onApply
        let start = current?.lowerBound ?? 1
        _from = State(initialValue: start)
        _to = State(initialValue: current?.upperBound ?? min(pageCount, limit))
    }

    /// What is wrong with the range as typed, in words; nil when it can be used.
    static func problem(from: Int, to: Int, pageCount: Int, limit: Int) -> String? {
        if from < 1 || to > pageCount || from > to { return "Pages run from 1 to \(pageCount)." }
        if to - from + 1 > limit { return "Choose up to \(limit) pages." }
        return nil
    }

    private var problem: String? { Self.problem(from: from, to: to, pageCount: pageCount, limit: limit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose pages")
                .font(Theme.Typography.rowTitle.weight(.semibold))
                .foregroundStyle(Theme.TextColor.primary)
            HStack(spacing: 8) {
                Text("From")
                TextField("From", value: $from, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .accessibilityLabel("First page")
                Text("to")
                TextField("To", value: $to, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .accessibilityLabel("Last page")
                Text("of \(pageCount)")
                    .foregroundStyle(Theme.TextColor.secondary)
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.TextColor.primary)
            if let problem {
                Text(problem)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Status.problem)
            } else {
                Text("\(to - from + 1) \(to - from + 1 == 1 ? "page" : "pages") will be sent.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
            }
            HStack {
                if pageCount <= limit {
                    Button("Use All Pages") { onApply(nil) }
                        .buttonStyle(.capsuleSecondary)
                }
                Spacer(minLength: 8)
                Button("Use These Pages") { onApply(from...to) }
                    .buttonStyle(.capsulePrimary)
                    .disabled(problem != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// One segment of a row of segments (the card counts).
private struct SegmentButton: View {
    var title: String
    var label: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.footnote.weight(isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Theme.TextColor.primary : Theme.TextColor.onControl)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.Surface.segmentSelected)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A choice shown as a pill, filled with the accent's tint when chosen.
private struct ChoiceChip: View {
    var title: String
    var isSelected: Bool
    var action: () -> Void

    @Environment(\.accentChoice) private var accent

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.footnote)
                .foregroundStyle(isSelected ? accent.light : Theme.TextColor.onControl)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(isSelected ? accent.flippedSurface : Theme.Surface.control))
                .overlay { if isSelected { Capsule().strokeBorder(accent.light.with(opacity: 0.5), lineWidth: 1) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Lays its children out in rows, starting a new row when one doesn't fit.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}

#if DEBUG
#Preview("Create with AI") {
    let settings = PreviewData.settings()
    let ai = AIAccountStore(secrets: InMemorySecretStore(), cacheStorage: AIModelCacheStorage(directory: FileManager.default.temporaryDirectory), settings: settings)
    return ComposerView()
        .environmentObject(ComposerModel(settings: settings, ai: ai))
        .environmentObject(PreviewData.store())
        .environmentObject(settings)
        .environmentObject(ai)
        .frame(width: 720, height: 680)
        .background(Theme.Surface.window)
        .preferredColorScheme(.dark)
}
#endif

#if DEBUG
extension ComposerModel {
    /// `-FishBrainSampleSources`: some chips to look at: pasted text, a picture, a PDF that is fine and one that
    /// is too long. Made on the spot; nothing real is read or sent.
    func addSampleSources() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainSampleSources-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func pdf(_ name: String, pages: Int) -> URL {
            let url = directory.appendingPathComponent(name)
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            if let context = CGContext(url as CFURL, mediaBox: &box, nil) {
                for _ in 0..<pages {
                    context.beginPDFPage(nil)
                    context.endPDFPage()
                }
                context.closePDF()
            }
            return url
        }
        // A plain grey picture, drawn with Core Graphics.
        var png: Data?
        if let context = CGContext(
            data: nil, width: 640, height: 420, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) {
            context.setFillColor(gray: 0.4, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 420))
            if let image = context.makeImage() {
                let output = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil)
                    if CGImageDestinationFinalize(destination) { png = output as Data }
                }
            }
        }
        var incoming: [IncomingSource] = [
            .file(pdf("Campbell Biology – Ch. 9.pdf", pages: 24)),
            .file(pdf("Human Anatomy, Full Book.pdf", pages: 840)),
        ]
        if let png { incoming.append(.image(png, name: "whiteboard.heic")) }
        incoming.append(.text(String(repeating: "glycolysis ATP ", count: 620)))
        await add(incoming)
        focus = "Focus on the steps of glycolysis and the Krebs cycle, and the ATP counts. Skip the history."
    }
}
#endif

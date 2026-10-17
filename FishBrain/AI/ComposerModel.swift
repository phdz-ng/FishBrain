import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - What comes in

/// Something dropped, pasted or chosen, before it has been read.
enum IncomingSource: Sendable, Equatable {
    case file(URL)
    case image(Data, name: String)
    case text(String)

    /// What is on a pasteboard: files first, then a picture, then text.
    @MainActor
    static func from(_ pasteboard: NSPasteboard) -> [IncomingSource] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return urls.map(IncomingSource.file) }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return [.image(data, name: "Pasted picture")]
        }
        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.text(text)]
        }
        return []
    }

    /// What a drop or a Paste command hands over.
    static func load(from providers: [NSItemProvider]) async -> [IncomingSource] {
        var result: [IncomingSource] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await fileURL(from: provider) { result.append(.file(url)) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let data = await imageData(from: provider) { result.append(.image(data, name: "Pasted picture")) }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                if let text = await string(from: provider) { result.append(.text(text)) }
            }
        }
        return result
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL { continuation.resume(returning: url) }
                else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    private static func imageData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func string(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: object as? String)
            }
        }
    }
}

/// One thing the person added, as the composer shows it: a chip.
struct ComposerItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case pdf, image, text }

    var id = UUID()
    /// What is sent. For a PDF with a range of pages chosen, only those pages.
    var source: GenerationSource
    /// The whole PDF, kept so the range of pages can be changed later.
    var fullPDF: PDFSource?
    var name: String
    /// "24 pages · 6.1 MB", "1,240 words".
    var detail: String
    /// A small picture for a picture; nil otherwise.
    var thumbnail: Data?
    /// For a PDF: how many characters of text it has (a scan has none). Only the on-device model needs it.
    var textCharacters: Int?

    var kind: Kind {
        switch source {
        case .pdf: .pdf
        case .image: .image
        case .text: .text
        }
    }

    /// "Campbell Biology – Ch. 9.pdf, 24 pages · 6.1 MB": what VoiceOver says for the chip.
    var accessibilityText: String { "\(name), \(detail)" }

    /// The pages of the original that are sent, when only some are.
    var pageRange: ClosedRange<Int>? {
        guard case .pdf(let pdf) = source, pdf.isExcerpt else { return nil }
        return pdf.firstPage...pdf.lastPage
    }

    var payloadBytes: Int {
        switch source {
        case .pdf(let pdf): pdf.data.count
        case .image(let image): image.data.count
        case .text(let text): text.text.utf8.count
        }
    }

    init(source: GenerationSource, fullPDF: PDFSource? = nil, thumbnail: Data? = nil, textCharacters: Int? = nil, id: UUID = UUID()) {
        self.id = id
        self.source = source
        self.thumbnail = thumbnail
        self.textCharacters = textCharacters
        switch source {
        case .pdf(let pdf):
            self.fullPDF = fullPDF ?? pdf
            name = pdf.filename
            detail = ComposerFormat.pdfDetail(pdf)
        case .image(let image):
            name = image.filename
            detail = "Picture · " + ComposerFormat.bytes(image.data.count)
        case .text(let text):
            name = text.name ?? "Pasted text"
            detail = ComposerFormat.words(ComposerFormat.wordCount(text.text))
        }
    }
}

/// The words the composer uses for sizes.
enum ComposerFormat {
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// "1,240 words" (the grouping follows the person's region).
    static func words(_ count: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        let number = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return "\(number) \(count == 1 ? "word" : "words")"
    }

    /// "24 pages · 6.1 MB", or "Pages 10–40 of 840 · 2.3 MB" when only some are sent.
    static func pdfDetail(_ pdf: PDFSource) -> String {
        let size = bytes(pdf.data.count)
        if pdf.isExcerpt, let total = pdf.originalPageCount {
            return "Pages \(pdf.firstPage)–\(pdf.lastPage) of \(total) · \(size)"
        }
        return "\(pdf.pageCount) \(pdf.pageCount == 1 ? "page" : "pages") · \(size)"
    }
}

/// Reads what was added into chips. Heavy (a big PDF is parsed), so it runs off the main actor.
enum ComposerSourceReader {
    static let thumbnailPixels = 68

    static func read(_ incoming: IncomingSource) -> Result<ComposerItem, SourceError> {
        do {
            switch incoming {
            case .file(let url):
                switch try GenerationInputs.source(at: url) {
                case .pdf(let pdf): return .success(ComposerItem(source: .pdf(pdf), textCharacters: OnDeviceMaterial.characters(in: pdf)))
                case .image(let image): return .success(ComposerItem(source: .image(image), thumbnail: thumbnail(for: image.data)))
                case .text(let text): return .success(ComposerItem(source: .text(text)))
                }
            case .image(let data, let name):
                let image = try GenerationInputs.image(from: data, filename: name)
                return .success(ComposerItem(source: .image(image), thumbnail: thumbnail(for: image.data)))
            case .text(let text):
                return .success(ComposerItem(source: .text(try GenerationInputs.pastedText(text))))
            }
        } catch let error as SourceError {
            return .failure(error)
        } catch {
            return .failure(.unreadable(filename: name(of: incoming)))
        }
    }

    private static func name(of incoming: IncomingSource) -> String {
        switch incoming {
        case .file(let url): url.lastPathComponent
        case .image(_, let name): name
        case .text: "Pasted text"
        }
    }

    static func thumbnail(for data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels * 2,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// The same PDF with only some of its pages (1-based, of the original).
    static func excerpt(of item: ComposerItem, pages: ClosedRange<Int>?) throws -> ComposerItem {
        guard let full = item.fullPDF else { throw SourceError.badPageRange }
        let original = full.originalPageCount ?? full.pageCount
        let source: PDFSource
        if let pages, pages != 1...original {
            source = try GenerationInputs.excerpt(of: full, pages: pages)
        } else {
            source = full
        }
        return ComposerItem(source: .pdf(source), fullPDF: full, textCharacters: OnDeviceMaterial.characters(in: source), id: item.id)
    }
}

// MARK: - The composer

/// What is wrong with a chip, said on the chip.
struct ComposerProblem: Equatable, Sendable {
    var message: String
    /// A PDF whose pages can be narrowed to fix it.
    var offersPageRange = false
}

/// Something that happened when adding that isn't about one chip (a file that couldn't be read).
struct ComposerNotice: Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String
}

/// Where the cards go.
enum ComposerDestination: Hashable, Sendable {
    case newDeck
    case deck(Deck.ID)
}

/// Whether Generate can be pressed, and if not why.
enum ComposerReadiness: Equatable, Sendable {
    case ready
    /// No provider has a key: the Generate row is replaced by a way to Settings.
    case needsProvider
    /// Nothing to make cards from: no source and nothing in the focus field.
    case needsInput
    /// A chip has a problem; it says what.
    case hasProblems
    /// The chosen model has already answered that it can't make cards from files.
    case modelCantMakeCards
}

/// The provider and model a run would use.
struct ComposerProvider: Equatable, Sendable {
    var provider: AIProvider
    var model: AIModel
    /// "Claude Opus 5.5 · your Anthropic key".
    var summary: String {
        provider.isOnDevice ? "Apple Intelligence · on this Mac, free" : "\(model.displayName) · your \(provider.displayName) key"
    }
}

/// The deck cards are being added to: its name and color are kept as they are.
struct TargetDeck: Equatable, Sendable {
    var id: Deck.ID
    var name: String
    var color: DeckColor
}

/// Whether "Generate…" inside a deck can open the form now.
enum DeckGenerateAvailability: Equatable, Sendable {
    case available
    /// No key: it is dimmed, and says why.
    case needsProvider
    /// A draft is waiting in Create with AI, and the form isn't free until it is dealt with.
    case draftInProgress

    var help: String {
        switch self {
        case .available: "Make cards for this deck with AI"
        case .needsProvider: "Set up an AI provider in Settings > AI first."
        case .draftInProgress: "Save or discard the draft in Create with AI first."
        }
    }
}

/// Everything needed to start a run, handed to the screen that does it (FLAS-50).
struct GenerationPlan {
    var request: GenerationRequest
    var destination: ComposerDestination
    /// Set when the cards go into a deck that exists: the draft then uses that deck's name and color.
    var targetDeck: TargetDeck?
    var provider: ComposerProvider
    /// A generator for the provider, holding the key; nil when the key can't be read.
    var makeGenerator: @Sendable () -> CardGenerator?
}

/// What the cost line shows.
enum ComposerCost: Equatable, Sendable {
    /// The setting is off, the price isn't known, or it can't be worked out: show nothing.
    case hidden
    case calculating
    case estimate(CostEstimate)
}

/// What the form held when a run started, so Start over can put it back.
struct ComposerSnapshot: Sendable {
    var items: [ComposerItem]
    var focus: String
    var style: CardStyle
    var languageName: String?
    var destination: ComposerDestination
    var countOverride: Int?
    var customCountChosen: Bool
}

/// Makes the generator for a provider, given its key.
typealias GeneratorFactory = @Sendable (ComposerProvider, String) -> CardGenerator

typealias CostEstimating = @Sendable (GenerationRequest, AIModel, String) async throws -> CostEstimate?

/// The state of the Create with AI screen: what has been added, what matters, how many cards, in what
/// style and language, and where they go. It lives for the whole session, so the screen is as it was left
/// after a visit to a deck. A run starting clears it (`reset()`).
@MainActor
final class ComposerModel: ObservableObject {
    static let presetCounts = [10, 20, 30, 50]
    static let countRange = 1...100
    /// The languages offered besides "Same as source".
    static let languages = [
        "English", "Spanish", "French", "German", "Italian", "Portuguese", "Dutch", "Swedish", "Norwegian", "Danish",
        "Finnish", "Polish", "Czech", "Hungarian", "Romanian", "Greek", "Turkish", "Russian", "Ukrainian", "Arabic",
        "Hebrew", "Hindi", "Vietnamese", "Thai", "Indonesian", "Chinese (Simplified)", "Chinese (Traditional)",
        "Japanese", "Korean",
    ]

    @Published private(set) var items: [ComposerItem] = []
    @Published private(set) var notices: [ComposerNotice] = []
    /// Files being read right now.
    @Published private(set) var readingCount = 0
    @Published var focus = ""
    @Published var style: CardStyle = .questionAnswer
    /// nil is "Same as source".
    @Published var languageName: String?
    @Published var destination: ComposerDestination = .newDeck
    @Published private(set) var cost: ComposerCost = .hidden
    /// "Custom" was chosen for the count, even if the number is one of the presets.
    @Published private var customCountChosen = false
    @Published private var countOverride: Int?
    /// The cards being made or reviewed. While there is one, the Create with AI screen shows it, not the form.
    @Published private(set) var draft: GenerationDraft? {
        didSet {
            // The sidebar shows the draft's progress ("9/20"), so a change in the draft is a change here.
            draftObservation = draft?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        }
    }
    private var draftObservation: AnyCancellable?

    private let settings: SettingsStore
    private let ai: AIAccountStore
    private let unsupported: UnsupportedModels
    private let costEstimator: CostEstimating
    private let generatorFactory: GeneratorFactory

    init(
        settings: SettingsStore, ai: AIAccountStore, unsupported: UnsupportedModels = .shared,
        costEstimator: @escaping CostEstimating = ComposerModel.estimateWithProvider,
        generatorFactory: @escaping GeneratorFactory = ComposerModel.realGenerator
    ) {
        self.settings = settings
        self.ai = ai
        self.unsupported = unsupported
        self.costEstimator = costEstimator
        self.generatorFactory = generatorFactory
    }

    nonisolated static let realGenerator: GeneratorFactory = { provider, key in
        switch provider.provider {
        case .anthropic: AnthropicCardGenerator(apiKey: key, model: provider.model)
        case .openAI: OpenAICardGenerator(apiKey: key, model: provider.model)
        case .appleIntelligence:
            AppleIntelligenceGenerator(
                engine: FoundationModelsEngine(),
                status: .available(contextSize: provider.model.maxInputTokens ?? OnDeviceStatus.defaultContextSize, supportsImages: provider.model.supportsImages == true)
            )
        }
    }

    // MARK: Count

    /// The cards asked for: what was chosen here, or the default from Settings.
    var cardCount: Int {
        get { countOverride ?? Self.clamp(settings.ai.cardsPerRun) }
        set { countOverride = Self.clamp(newValue) }
    }

    var isCustomCount: Bool { customCountChosen || !Self.presetCounts.contains(cardCount) }

    func choosePreset(_ count: Int) {
        customCountChosen = false
        cardCount = count
    }

    func chooseCustom() { customCountChosen = true }

    static func clamp(_ count: Int) -> Int { min(max(count, countRange.lowerBound), countRange.upperBound) }

    // MARK: Provider

    /// The provider that would make the cards: the default one if it has a key, else any that does.
    var activeProvider: ComposerProvider? {
        // The on-device model is only used when it was chosen: it is a smaller model, and being free is no reason to
        // switch to it behind anyone's back.
        let preferred = settings.ai.provider.flatMap { ai.isUsable($0) ? $0 : nil }
        guard let provider = preferred ?? AIProvider.cloud.first(where: { ai.hasKey($0) }) else { return nil }
        let model = ai.selectedModel(for: provider) ?? {
            let id = settings.ai.model(for: provider) ?? provider.recommendedModelID
            return AIModel(provider: provider, id: id, displayName: id, created: nil)
        }()
        return ComposerProvider(provider: provider, model: model)
    }

    // MARK: Sources

    var hasInput: Bool { !items.isEmpty || !focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Reads what was added and adds a chip for each; what can't be read becomes a notice.
    func add(_ incoming: [IncomingSource]) async {
        guard !incoming.isEmpty else { return }
        readingCount += incoming.count
        let results = await Task.detached { incoming.map(ComposerSourceReader.read) }.value
        readingCount -= incoming.count
        for result in results {
            switch result {
            case .success(let item): items.append(item)
            case .failure(let error): notices.append(ComposerNotice(text: error.message))
            }
        }
    }

    func addFiles(_ urls: [URL]) async { await add(urls.map(IncomingSource.file)) }

    /// The Paste button: whatever the clipboard holds that can be used.
    func addFromPasteboard(_ pasteboard: NSPasteboard = .general) async {
        let incoming = IncomingSource.from(pasteboard)
        if incoming.isEmpty {
            let text = "The clipboard has nothing FishBrain can use. Copy a file, a picture or some text first."
            if !notices.contains(where: { $0.text == text }) { notices.append(ComposerNotice(text: text)) }
            return
        }
        await add(incoming)
    }

    func remove(_ id: ComposerItem.ID) { items.removeAll { $0.id == id } }

    func dismissNotice(_ id: ComposerNotice.ID) { notices.removeAll { $0.id == id } }

    /// Sends only some pages of a PDF (nil sends them all).
    func setPages(_ range: ClosedRange<Int>?, for id: ComposerItem.ID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        do {
            let updated = try await Task.detached { try ComposerSourceReader.excerpt(of: item, pages: range) }.value
            if let index = items.firstIndex(where: { $0.id == id }) { items[index] = updated }
        } catch {
            notices.append(ComposerNotice(text: (error as? SourceError)?.message ?? SourceError.badPageRange.message))
        }
    }

    /// A run has started: the next visit begins with an empty form.
    func reset() {
        items = []
        notices = []
        focus = ""
        style = .questionAnswer
        languageName = nil
        destination = .newDeck
        countOverride = nil
        customCountChosen = false
        cost = .hidden
    }

    // MARK: Problems

    /// The most pages that can be sent: 600, or fewer for a model with a small context window.
    var maxPDFPages: Int {
        guard let active = activeProvider, active.provider == .anthropic else { return SourceLimits.maxPDFPages }
        return AnthropicCapabilities(model: active.model).maxPDFPages
    }

    /// What is wrong with each chip, keyed by chip.
    var problems: [ComposerItem.ID: ComposerProblem] {
        var found: [ComposerItem.ID: ComposerProblem] = [:]
        let limit = maxPDFPages
        let canReadPictures = activeProvider.map { $0.model.supportsImages != false } ?? true
        let onDevice = activeProvider?.provider.isOnDevice == true

        for item in items {
            switch item.source {
            case .pdf(let pdf) where pdf.pageCount > limit:
                found[item.id] = ComposerProblem(
                    message: limit < SourceLimits.maxPDFPages
                        ? "This PDF has \(pdf.pageCount) pages. This model reads up to \(limit)."
                        : "This PDF has \(pdf.pageCount) pages. Choose up to \(limit).",
                    offersPageRange: true
                )
            case .image where !canReadPictures:
                found[item.id] = ComposerProblem(message: onDevice
                    ? "Apple Intelligence can't read pictures on this Mac. Choose Anthropic or OpenAI in Settings, or remove the picture."
                    : GenerationError.imagesNotSupported.message)
            default:
                break
            }
        }

        // The on-device model reads words, not scanned pages.
        if onDevice {
            for item in items where item.kind == .pdf && (item.textCharacters ?? 1) < Self.minimumReadableCharacters && found[item.id] == nil {
                found[item.id] = ComposerProblem(message: GenerationError.noReadableText.message)
            }
        }

        // Together the PDFs can be too long even when each one is fine: say so on the longest.
        let pdfs = items.filter { $0.kind == .pdf }
        let total = pdfs.reduce(0) { total, item in
            if case .pdf(let pdf) = item.source { total + pdf.pageCount } else { total }
        }
        if found.isEmpty, total > limit, let longest = pdfs.max(by: { pageCount($0) < pageCount($1) }) {
            found[longest.id] = ComposerProblem(
                message: "Together the PDFs have \(total) pages; at most \(limit) can be sent at once. Choose fewer pages.",
                offersPageRange: true
            )
        }

        // Too heavy overall: say so on the biggest.
        if found.isEmpty, case .tooBig? = sizeProblem, let biggest = items.max(by: { $0.payloadBytes < $1.payloadBytes }) {
            found[biggest.id] = ComposerProblem(message: sizeProblem?.message ?? "", offersPageRange: biggest.kind == .pdf)
        }
        return found
    }

    /// A PDF with fewer characters than this has no text to speak of.
    static let minimumReadableCharacters = 20

    /// For the on-device model: more material than it can read in one run. Not a problem (it makes cards from the
    /// first part), but something to say before the person presses Generate.
    var onDeviceNote: String? {
        guard let active = activeProvider, active.provider.isOnDevice else { return nil }
        // Nothing to read: it writes from what it knows, and a small model gets facts wrong.
        if items.isEmpty, hasInput {
            return "With no notes or PDF to read, Apple Intelligence writes from what it knows, and a model this small gets facts wrong. Add your material for cards you can trust, and check these ones."
        }
        let total = items.reduce(0) { total, item in
            switch item.source {
            case .pdf: total + (item.textCharacters ?? 0)
            case .text(let text): total + text.text.count
            case .image: total
            }
        }
        let capacity = OnDeviceChunker.capacity(contextSize: active.model.maxInputTokens ?? OnDeviceStatus.defaultContextSize)
        guard total > capacity else { return nil }
        let words = { (characters: Int) in ComposerFormat.words(characters / 6) }
        return "Apple Intelligence reads about \(words(capacity)) in one go, and yours has about \(words(total)). Cards will come from the first part. Choose fewer pages, or use Anthropic or OpenAI to use all of it."
    }

    private func pageCount(_ item: ComposerItem) -> Int {
        if case .pdf(let pdf) = item.source { pdf.pageCount } else { 0 }
    }

    private var sizeProblem: SizeProblem? {
        GenerationRequest(sources: items.map(\.source), focus: focus, modelID: "").sizeProblem
    }

    // MARK: Ready?

    var readiness: ComposerReadiness {
        guard let active = activeProvider else { return .needsProvider }
        guard hasInput else { return .needsInput }
        if !problems.isEmpty { return .hasProblems }
        if unsupported.contains(active.model.id, provider: active.provider) { return .modelCantMakeCards }
        return .ready
    }

    var canGenerate: Bool { readiness == .ready }

    /// The run as asked for. `decks` lets "put cards in" an existing deck pass its fronts along, so the
    /// model doesn't repeat them.
    func request(decks: [Deck]) -> GenerationRequest? {
        guard let active = activeProvider else { return nil }
        var existing: [String] = []
        if case .deck(let id) = destination, let deck = decks.first(where: { $0.id == id }) {
            existing = deck.cards.map(\.front)
        }
        return GenerationRequest(
            sources: items.map(\.source),
            focus: focus.trimmingCharacters(in: .whitespacesAndNewlines),
            cardCount: cardCount,
            style: style,
            language: languageName.map(CardLanguage.named) ?? .sameAsSource,
            existingFronts: existing,
            modelID: active.model.id
        )
    }

    /// Where the cards go, if that deck still exists.
    func resolvedDestination(in decks: [Deck]) -> ComposerDestination {
        if case .deck(let id) = destination, decks.contains(where: { $0.id == id }) { return destination }
        return .newDeck
    }

    /// Everything a run needs, or nil when it can't start.
    func plan(decks: [Deck]) -> GenerationPlan? {
        guard canGenerate, let active = activeProvider, let request = request(decks: decks) else { return nil }
        // The on-device model has no key; "" stands in so the factory is asked all the same.
        let key = active.provider.needsKey ? ai.apiKey(for: active.provider) : ""
        let factory = generatorFactory
        let destination = resolvedDestination(in: decks)
        var target: TargetDeck?
        if case .deck(let id) = destination, let deck = decks.first(where: { $0.id == id }) {
            target = TargetDeck(id: id, name: deck.name, color: deck.color)
        }
        return GenerationPlan(request: request, destination: destination, targetDeck: target, provider: active) {
            key.map { factory(active, $0) }
        }
    }

    // MARK: From inside a deck

    var deckGenerateAvailability: DeckGenerateAvailability {
        if draft != nil { return .draftInProgress }
        return activeProvider == nil ? .needsProvider : .available
    }

    /// "Generate…" on a deck: the form's "Put cards in" becomes that deck (what else was in the form stays).
    /// False when the form can't be used now.
    @discardableResult
    func prepareForDeck(_ id: Deck.ID) -> Bool {
        guard deckGenerateAvailability == .available else { return false }
        destination = .deck(id)
        return true
    }

    // MARK: Runs

    var snapshot: ComposerSnapshot {
        ComposerSnapshot(
            items: items, focus: focus, style: style, languageName: languageName, destination: destination,
            countOverride: countOverride, customCountChosen: customCountChosen
        )
    }

    func restore(_ snapshot: ComposerSnapshot) {
        items = snapshot.items
        notices = []
        focus = snapshot.focus
        style = snapshot.style
        languageName = snapshot.languageName
        destination = snapshot.destination
        countOverride = snapshot.countOverride
        customCountChosen = snapshot.customCountChosen
        cost = .hidden
    }

    /// Presses Generate: the form is kept aside, the screen becomes the draft, and the cards start to arrive.
    @discardableResult
    func startRun(decks: [Deck]) -> GenerationDraft? {
        guard draft == nil, let plan = plan(decks: decks) else { return nil }
        let draft = GenerationDraft(plan: plan, snapshot: snapshot)
        draft.onClose = { [weak self] in self?.draft = nil }
        self.draft = draft
        reset()
        draft.start()
        return draft
    }

    /// Back to the form with what was in it, throwing the draft away.
    func startOver() {
        guard let draft else { return }
        draft.cancelAll()
        self.draft = nil
        restore(draft.snapshot)
    }

    /// Throws the draft away and leaves the form empty.
    func discardDraft() {
        draft?.cancelAll()
        draft = nil
    }

    /// Cards that haven't been saved: quitting should ask first.
    var hasUnsavedDraft: Bool { draft?.hasUnsavedWork ?? false }

    /// What the sidebar row says about the draft: "9/20", "Draft", or nothing.
    var draftBadge: String? { draft?.badge }

    // MARK: Cost

    /// Changes whenever something that changes the cost does, so the screen can ask again.
    func costKey(decks: [Deck]) -> Int {
        var hasher = Hasher()
        hasher.combine(items.map { "\($0.id)-\($0.pageRange.map { "\($0)" } ?? "")" })
        hasher.combine(focus)
        hasher.combine(cardCount)
        hasher.combine(style)
        hasher.combine(languageName)
        hasher.combine(resolvedDestination(in: decks))
        hasher.combine(activeProvider?.model.id)
        hasher.combine(activeProvider?.provider)
        hasher.combine(settings.ai.showsCostEstimate)
        return hasher.finalize()
    }

    /// Works out the cost line. Anthropic is asked to count the tokens (it can); OpenAI's is a guess from the
    /// size. Nothing shows when the setting is off, the price isn't known, or it can't be worked out.
    func refreshCost(decks: [Deck]) async {
        guard settings.ai.showsCostEstimate, canGenerate, let active = activeProvider,
              AIPricing.price(for: active.model.id) != nil,
              let request = request(decks: decks), let key = active.provider.needsKey ? ai.apiKey(for: active.provider) : ""
        else {
            cost = .hidden
            return
        }
        cost = .calculating
        do {
            let estimate = try await costEstimator(request, active.model, key)
            guard !Task.isCancelled else { return }
            cost = estimate.map(ComposerCost.estimate) ?? .hidden
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { cost = .hidden }
        }
    }

    nonisolated static let estimateWithProvider: CostEstimating = { request, model, key in
        switch model.provider {
        case .anthropic: try await AnthropicCardGenerator(apiKey: key, model: model).estimateCost(for: request)
        case .openAI: try await OpenAICardGenerator(apiKey: key, model: model).estimateCost(for: request)
        case .appleIntelligence: nil // free, so there is nothing to estimate
        }
    }
}

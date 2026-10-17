import Foundation

// MARK: - What is asked for

/// How the cards are laid out.
enum CardStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case questionAnswer, termDefinition, cloze

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .questionAnswer: "Question → Answer"
        case .termDefinition: "Term → Definition"
        case .cloze: "Fill in the blank"
        }
    }
}

/// The language the cards are written in.
enum CardLanguage: Equatable, Sendable {
    case sameAsSource
    case named(String)
}

/// A PDF to make cards from. When only some pages were chosen, `data` holds just those pages and
/// `firstPage` says where they start in the original, so page numbers on the cards still match it.
struct PDFSource: Equatable, Sendable {
    var data: Data
    var filename: String
    /// Pages in `data`.
    var pageCount: Int
    /// The page of the original that `data` starts at.
    var firstPage = 1
    /// How many pages the original has (equal to `pageCount` unless an excerpt was taken).
    var originalPageCount: Int?

    var isExcerpt: Bool { firstPage > 1 || (originalPageCount.map { $0 != pageCount } ?? false) }
    var lastPage: Int { firstPage + pageCount - 1 }
}

/// A picture to make cards from, already scaled for sending.
struct ImageSource: Equatable, Sendable {
    var data: Data
    /// `image/jpeg` or `image/png`.
    var mediaType: String
    var filename: String
}

/// Notes or an article, pasted or read from a .txt, .md or .csv file.
struct TextSource: Equatable, Sendable {
    var text: String
    var name: String?
}

enum GenerationSource: Equatable, Sendable {
    case pdf(PDFSource)
    case image(ImageSource)
    case text(TextSource)
}

/// A card as it is shown to the model when it is asked to change the cards the person has. `editedByPerson`
/// is only there (and true) for cards the person changed by hand.
struct RefineCard: Codable, Equatable, Sendable {
    var front: String
    var back: String
    var sourcePage: Int?
    var editedByPerson: Bool?

    init(front: String, back: String, sourcePage: Int?, editedByPerson: Bool = false) {
        self.front = front
        self.back = back
        self.sourcePage = sourcePage
        self.editedByPerson = editedByPerson ? true : nil
    }
}

/// What a run is for.
enum GenerationTask: Equatable, Sendable {
    /// Make cards from the sources.
    case create
    /// Change the cards the person has now, as asked ("make the answers shorter", "add 5 more on ...").
    /// The answer is the whole deck again.
    case refine(instruction: String, deckName: String, cards: [RefineCard])
    /// One new card to take the place of this one.
    case replace(card: RefineCard, deckName: String)
}

/// Everything a provider needs to make a deck.
struct GenerationRequest: Equatable, Sendable {
    var sources: [GenerationSource]
    /// What matters to the person, in their own words. May be empty.
    var focus: String
    var cardCount: Int
    var style: CardStyle
    var language: CardLanguage
    /// Fronts of the cards the deck already has, so the model doesn't repeat them.
    var existingFronts: [String]
    var task: GenerationTask
    var modelID: String

    init(
        sources: [GenerationSource], focus: String = "", cardCount: Int = AISettings.defaultCardsPerRun,
        style: CardStyle = .questionAnswer, language: CardLanguage = .sameAsSource,
        existingFronts: [String] = [], task: GenerationTask = .create, modelID: String
    ) {
        self.sources = sources
        self.focus = focus
        self.cardCount = cardCount
        self.style = style
        self.language = language
        self.existingFronts = existingFronts
        self.task = task
        self.modelID = modelID
    }
}

// MARK: - What comes back

struct GeneratedCard: Codable, Equatable, Sendable {
    var front: String
    var back: String
    /// The 1-based page of the PDF the card is based on, when there is one.
    var sourcePage: Int?
}

struct GeneratedDeck: Codable, Equatable, Sendable {
    var deckName: String
    var cards: [GeneratedCard]
}

struct GenerationUsage: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
}

/// What a provider reports as it works: the deck's name as soon as it is written, each card as soon as
/// it is finished, and at the end what was used.
enum GenerationEvent: Equatable, Sendable {
    case deckName(String)
    case card(GeneratedCard)
    case finished(GenerationUsage?)
}

/// Makes a deck from a request. One implementation per provider; both stream, so cards can be shown as
/// they are written.
protocol CardGenerator: Sendable {
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
}

/// Why making cards failed, in words a person can act on.
enum GenerationError: Error, Equatable, Sendable {
    case invalidKey
    /// The key is fine but isn't allowed to use the chosen model.
    case modelForbidden
    /// The chosen model is gone; the model list should be refreshed.
    case modelUnavailable
    /// The sources include pictures and the chosen model can't read them.
    case imagesNotSupported
    /// The provider turned the request down as a bad one for this model (it can't take files or pictures, or
    /// structured output). The model should be marked as unsupported for the session.
    case modelCantMakeCards
    /// The account has no credit left.
    case outOfCredit
    /// The on-device model can't write in the language of the material.
    case languageNotSupported
    /// Apple Intelligence isn't ready on this Mac (off, still downloading, or this Mac can't run it).
    case onDeviceUnavailable
    /// Nothing in the PDFs or texts could be read as words (scanned pages), and the model can only read words.
    case noReadableText
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case tooLarge
    /// The model declined to make cards from this material.
    case refused
    /// The answer was cut off (it ran out of room). Cards already written are kept.
    case truncated
    case network
    case badResponse

    init(_ error: AIError) {
        switch error {
        case .rejected: self = .invalidKey
        case .network: self = .network
        case .rateLimited: self = .rateLimited(retryAfter: nil)
        case .unavailable: self = .overloaded
        case .unexpected, .badResponse: self = .badResponse
        }
    }

    /// The model list is out of date (or the key changed): the composer should ask the provider for it again.
    var needsModelListRefresh: Bool { self == .modelForbidden || self == .modelUnavailable }

    var message: String {
        switch self {
        case .invalidKey: "The provider rejected your key. Check it in Settings."
        case .modelForbidden: "This key can't use this model. Choose another model in Settings."
        case .modelUnavailable: "This model is no longer available. Choose another model in Settings."
        case .imagesNotSupported: "This model can't read pictures. Choose another model, or remove the pictures."
        case .modelCantMakeCards: "This model can't make cards from these files. Pick another model in Settings → AI."
        case .outOfCredit: "Your OpenAI account is out of credit. Add credit at platform.openai.com, then try again."
        case .languageNotSupported: "Apple Intelligence can't write in this language. Choose Anthropic or OpenAI in Settings, or use material in another language."
        case .onDeviceUnavailable: "Apple Intelligence isn't ready on this Mac. Check it is turned on in System Settings, then try again."
        case .noReadableText: "There are no words FishBrain can read in this (scanned pages have none). Apple Intelligence reads text only: choose Anthropic or OpenAI in Settings."
        case .rateLimited(let wait):
            wait.map { "Too many requests. Try again in \(max(Int($0.rounded(.up)), 1)) seconds." } ?? "Too many requests. Try again in a moment."
        case .overloaded: "The service is busy. Try again in a moment."
        case .tooLarge: "That's too much to send at once. Use fewer files, or choose a range of pages."
        case .refused: "The model declined to make cards from this material."
        case .truncated: "The answer was cut off. The cards so far are kept."
        case .network: "No network connection"
        case .badResponse: "The answer wasn't what FishBrain expected."
        }
    }
}

/// Whether a run gave the number of cards asked for. The schema can't say how many, so it is checked here.
struct CountCheck: Equatable, Sendable {
    var requested: Int
    /// The cards to use: the first `requested` of what came back.
    var cards: [GeneratedCard]
    /// How many came back beyond what was asked for, and were left out.
    var surplus: Int

    init(requested: Int, received: [GeneratedCard]) {
        self.requested = requested
        cards = Array(received.prefix(max(requested, 0)))
        surplus = max(received.count - max(requested, 0), 0)
    }

    var missing: Int { max(requested - cards.count, 0) }
    var isComplete: Bool { missing == 0 }

    /// "Got 17 of 20", or nil when it is as asked.
    var shortfallText: String? { isComplete ? nil : "Got \(cards.count) of \(requested)" }
    /// "Add 3 more", the button that asks for what is missing.
    var addMoreText: String? { isComplete ? nil : "Add \(missing) more" }
}

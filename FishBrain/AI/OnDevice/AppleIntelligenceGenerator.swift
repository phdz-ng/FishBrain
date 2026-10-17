import Foundation

// MARK: - The seam to the model

/// A card as the model is part-way through writing it: any of its parts may not be there yet.
struct OnDevicePartialCard: Equatable, Sendable {
    var front: String?
    var back: String?
    var sourcePage: Int?
}

/// The deck as the model is part-way through writing it. The name comes first, then the cards in order.
struct OnDevicePartialDeck: Equatable, Sendable {
    var deckName: String?
    var cards: [OnDevicePartialCard] = []
}

/// What one call to the model is given.
struct OnDeviceRequest: Equatable, Sendable {
    var instructions: String
    var prompt: String
    /// A picture to look at (only for a model that can).
    var image: Data?
}

/// Why the model couldn't answer, in the system's terms.
enum OnDeviceFailure: Error, Equatable, Sendable {
    /// The question and answer together would be longer than the model can hold.
    case contextExceeded
    /// The system's safety checks stopped it.
    case guardrail
    case refusal
    /// It can't write in this language.
    case unsupportedLanguage
    /// The model isn't downloaded or ready.
    case assetsUnavailable
    case rateLimited
    /// The model is busy with something else.
    case busy
    /// What came back couldn't be read.
    case decoding
    case other
}

/// The model, as the generator uses it: a request in, the deck as it takes shape out. The real one is
/// `FoundationModelsEngine`; tests use their own.
protocol OnDeviceEngine: Sendable {
    func stream(_ request: OnDeviceRequest) -> AsyncThrowingStream<OnDevicePartialDeck, Error>
}

// MARK: - What each call says

enum OnDevicePrompt {
    /// Only this many fronts are named to avoid repeating, each cut short: the context is small.
    static let maxFrontsToAvoid = 25
    static let maxFrontLength = 80

    static func request(for call: OnDevicePlan.Call, original: GenerationRequest, avoid: [String]) -> OnDeviceRequest {
        var derived = original
        derived.cardCount = max(call.cards, 1)
        derived.existingFronts = avoid.suffix(maxFrontsToAvoid).map { String($0.prefix(maxFrontLength)) }
        // What the words of the request say depends on there being material, not on what it is.
        derived.sources = call.chunk == nil ? [] : [.text(TextSource(text: " ", name: nil))]

        var prompt = ""
        if let chunk = call.chunk, !chunk.text.isEmpty { prompt += "Material:\n\(chunk.text)\n\n" }
        prompt += GenerationPrompt.instructions(for: derived)
        if call.chunk?.firstPage != nil {
            prompt += "\n\nThe material marks each page like [Page 12]. Set sourcePage to the number of the page the card is based on."
        }
        return OnDeviceRequest(instructions: GenerationPrompt.system, prompt: prompt, image: call.chunk?.image)
    }
}

// MARK: - Cards as they finish

/// Turns the deck as it takes shape into events, as the name and each card are done. Strings arrive a few letters
/// at a time, so a card is done once the model has started the next one (or the answer has ended).
struct OnDeviceStreamTracker {
    /// The most cards to let through.
    var limit: Int
    private(set) var emitted = 0
    private var nameSent = false

    init(limit: Int) { self.limit = limit }

    /// The name, if it has been written (the model writes it first, so it is done once cards begin) and not sent yet.
    mutating func update(_ deck: OnDevicePartialDeck, isFinal: Bool, wantsName: Bool = true) -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        let cards = deck.cards
        if wantsName, !nameSent, !cards.isEmpty || isFinal,
           let name = deck.deckName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            nameSent = true
            events.append(.deckName(name))
        }
        let done = isFinal ? cards.count : max(cards.count - 1, 0)
        while emitted < done, emitted < limit {
            let card = cards[emitted]
            emitted += 1
            guard let front = card.front?.trimmingCharacters(in: .whitespacesAndNewlines), !front.isEmpty,
                  let back = card.back?.trimmingCharacters(in: .whitespacesAndNewlines), !back.isEmpty else { continue }
            events.append(.card(GeneratedCard(front: front, back: back, sourcePage: card.sourcePage.flatMap { $0 > 0 ? $0 : nil })))
        }
        return events
    }
}

// MARK: - What the small model gets wrong

/// The on-device model is small and sometimes writes the name of a field into a card ("... (sourcePage: 1)") or makes up a
/// page. This puts that right: the fragment is taken out, and a page number only stays if the material had such a page.
enum OnDeviceCleaner {
    private static let fragment = try! NSRegularExpression(
        pattern: #"\s*[\(\[]\s*source\s*_?page\s*[:=]?\s*(?:\d+|nil|null|none)\s*[\)\]]|\s*[;,.]?\s*source\s*_?page\s*[:=]\s*(?:\d+|nil|null|none)\s*$"#,
        options: [.caseInsensitive]
    )

    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return fragment.stringByReplacingMatches(in: text, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `pages` is the pages the part of the material was from (nil when it had no page marks).
    static func clean(_ card: GeneratedCard, pages: ClosedRange<Int>?) -> GeneratedCard {
        let page = card.sourcePage.flatMap { page in pages.map { $0.contains(page) ? page : nil } ?? nil }
        return GeneratedCard(front: clean(card.front), back: clean(card.back), sourcePage: page)
    }
}

// MARK: - The generator

/// Makes cards with the model that comes with the Mac: nothing leaves it, no key, no cost. The model's context is
/// small, so the material is cut into parts, each part makes its share of the cards, and they are written one part
/// after another. Only text can be read (a PDF needs words in it, not scanned pages), and pictures when the model can
/// look at them.
struct AppleIntelligenceGenerator: CardGenerator {
    var engine: any OnDeviceEngine
    var status: OnDeviceStatus

    /// A part that is too long for the model is cut in half and tried again, this many times at most.
    static let maxSplits = 3

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await run(request, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Reading what was given

    /// The words of every PDF and text, in order, and every picture.
    static func material(of request: GenerationRequest) -> (units: [MaterialUnit], images: [Data]) {
        var units: [MaterialUnit] = []
        var images: [Data] = []
        for source in request.sources {
            switch source {
            case .pdf(let pdf): units += OnDeviceMaterial.units(from: pdf)
            case .text(let text): units += OnDeviceMaterial.units(from: text)
            case .image(let image): images.append(image.data)
            }
        }
        return (units, images)
    }

    /// The answer to a refine or a rewrite works from the cards, not the material.
    private func plan(for request: GenerationRequest) throws -> OnDevicePlan {
        if case .create = request.task {
            let (units, images) = Self.material(of: request)
            if !request.sources.isEmpty, units.isEmpty, images.isEmpty { throw GenerationError.noReadableText }
            if !images.isEmpty, !status.supportsImages { throw GenerationError.imagesNotSupported }
            return OnDevicePlanner.plan(units: units, images: status.supportsImages ? images : [], cardCount: request.cardCount, contextSize: status.contextSize)
        }
        return OnDevicePlan(calls: [.init(chunk: nil, cards: max(request.cardCount, 1))], totalCharacters: 0, usedCharacters: 0)
    }

    // MARK: Running

    private func run(_ request: GenerationRequest, _ continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async throws {
        guard status.isAvailable else { throw GenerationError.onDeviceUnavailable }
        guard case .create = request.task else {
            try await runOne(.init(chunk: nil, cards: max(request.cardCount, 1)), request, avoid: request.existingFronts, wantsName: true, limit: .max, continuation)
            continuation.yield(.finished(nil))
            return
        }

        let plan = try plan(for: request)
        var avoid = request.existingFronts
        var produced = 0
        var skipped = 0
        var nameSent = false
        for call in plan.calls {
            try Task.checkCancellation()
            do {
                let fronts = try await runOne(call, request, avoid: avoid, wantsName: !nameSent, limit: call.cards, continuation)
                nameSent = true
                produced += fronts.count
                avoid += fronts
            } catch GenerationError.refused {
                skipped += 1 // the system's safety checks stopped this part; the others may be fine
            }
        }
        if produced == 0, skipped > 0 { throw GenerationError.refused }
        continuation.yield(.finished(nil))
    }

    /// One call. Returns the fronts it wrote. A part the model finds too long is cut in half and done as two.
    @discardableResult
    private func runOne(
        _ call: OnDevicePlan.Call, _ request: GenerationRequest, avoid: [String], wantsName: Bool, limit: Int,
        splits: Int = 0, _ continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws -> [String] {
        var tracker = OnDeviceStreamTracker(limit: limit)
        var written: [String] = []
        var last = OnDevicePartialDeck()
        let modelRequest = OnDevicePrompt.request(for: call, original: request, avoid: avoid)
        let pages: ClosedRange<Int>? = call.chunk.flatMap { chunk in
            guard let first = chunk.firstPage, let last = chunk.lastPage else { return nil }
            return first...last
        }
        do {
            for try await deck in engine.stream(modelRequest) {
                try Task.checkCancellation()
                last = deck
                for event in tracker.update(deck, isFinal: false, wantsName: wantsName) { emit(event, pages: pages, &written, continuation) }
            }
            for event in tracker.update(last, isFinal: true, wantsName: wantsName) { emit(event, pages: pages, &written, continuation) }
            return written
        } catch let failure as OnDeviceFailure {
            // Cards already shown stay. A part that was too long is cut in two, once the cards so far are counted.
            if failure == .contextExceeded, splits < Self.maxSplits, let chunk = call.chunk, chunk.image == nil, chunk.text.count >= 2 * OnDeviceChunker.minCharacters {
                let halves = OnDeviceChunker.cut(chunk.text, into: chunk.text.count / 2 + 50)
                let share = OnDeviceChunker.distribute(max(call.cards - written.count, 1), weights: halves.map(\.count))
                var more = written
                for (half, cards) in zip(halves, share) {
                    let piece = OnDevicePlan.Call(chunk: MaterialChunk(text: half, firstPage: chunk.firstPage, lastPage: chunk.lastPage), cards: cards)
                    more += try await runOne(piece, request, avoid: avoid + more, wantsName: false, limit: cards, splits: splits + 1, continuation)
                }
                return more
            }
            throw Self.error(for: failure)
        }
    }

    private func emit(_ event: GenerationEvent, pages: ClosedRange<Int>?, _ written: inout [String], _ continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) {
        guard case .card(let raw) = event else {
            continuation.yield(event)
            return
        }
        let card = OnDeviceCleaner.clean(raw, pages: pages)
        guard !card.front.isEmpty, !card.back.isEmpty else { return }
        written.append(card.front)
        continuation.yield(.card(card))
    }

    // MARK: Errors

    static func error(for failure: OnDeviceFailure) -> GenerationError {
        switch failure {
        case .contextExceeded: .tooLarge
        case .guardrail, .refusal: .refused
        case .unsupportedLanguage: .languageNotSupported
        case .assetsUnavailable: .onDeviceUnavailable
        case .rateLimited: .rateLimited(retryAfter: nil)
        case .busy: .overloaded
        case .decoding, .other: .badResponse
        }
    }
}

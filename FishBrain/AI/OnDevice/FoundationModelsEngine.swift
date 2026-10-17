import CoreGraphics
import Foundation
import ImageIO
#if canImport(FoundationModels)
import FoundationModels

/// The deck as the on-device model is asked to write it: guided generation, so the answer has this shape and no
/// JSON schema is needed. The name is first so it is written (and can be shown) before the cards.
@available(macOS 26.0, *)
@Generable(description: "A deck of flashcards made from the material")
private struct GeneratedDeckShape {
    @Guide(description: "A short, specific name for the deck, at most 6 words")
    var deckName: String
    @Guide(description: "The flashcards, each about one fact or idea")
    var cards: [GeneratedCardShape]
}

@available(macOS 26.0, *)
@Generable(description: "One flashcard")
private struct GeneratedCardShape {
    @Guide(description: "What to ask: a question, a term, or a sentence with a blank. It never contains the answer.")
    var front: String
    @Guide(description: "The answer, in as few words as will do")
    var back: String
    @Guide(description: "The page of the material the card is based on, or nil when there are no page marks")
    var sourcePage: Int?
}

/// The real model: a session with the system's language model, answering with guided generation and streaming the
/// deck as it takes shape.
struct FoundationModelsEngine: OnDeviceEngine {
    func stream(_ request: OnDeviceRequest) -> AsyncThrowingStream<OnDevicePartialDeck, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard #available(macOS 26.0, *) else {
                    continuation.finish(throwing: OnDeviceFailure.assetsUnavailable)
                    return
                }
                do {
                    try await Self.run(request, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.failure(from: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @available(macOS 26.0, *)
    private static func run(_ request: OnDeviceRequest, _ continuation: AsyncThrowingStream<OnDevicePartialDeck, Error>.Continuation) async throws {
        let session = LanguageModelSession(model: .default, instructions: request.instructions)
        let responses: LanguageModelSession.ResponseStream<GeneratedDeckShape>
        if let data = request.image {
            #if compiler(>=6.4)
            if #available(macOS 27.0, *), let image = cgImage(from: data) {
                responses = session.streamResponse(generating: GeneratedDeckShape.self) {
                    request.prompt
                    Attachment(image)
                }
            } else {
                responses = session.streamResponse(to: request.prompt, generating: GeneratedDeckShape.self)
            }
            #else
            responses = session.streamResponse(to: request.prompt, generating: GeneratedDeckShape.self)
            #endif
        } else {
            responses = session.streamResponse(to: request.prompt, generating: GeneratedDeckShape.self)
        }
        for try await snapshot in responses {
            try Task.checkCancellation()
            let partial = snapshot.content
            continuation.yield(OnDevicePartialDeck(
                deckName: partial.deckName,
                cards: (partial.cards ?? []).map { OnDevicePartialCard(front: $0.front, back: $0.back, sourcePage: $0.sourcePage ?? nil) }
            ))
        }
    }

    private static func cgImage(from data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    /// What the framework threw, in the generator's terms. (macOS 26 and 27 name these differently, so both are read.)
    static func failure(from error: Error) -> Error {
        if error is CancellationError { return error }
        if let failure = error as? OnDeviceFailure { return failure }
        if #available(macOS 26.0, *), let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize: return OnDeviceFailure.contextExceeded
            case .assetsUnavailable: return OnDeviceFailure.assetsUnavailable
            case .guardrailViolation: return OnDeviceFailure.guardrail
            case .unsupportedLanguageOrLocale: return OnDeviceFailure.unsupportedLanguage
            case .decodingFailure: return OnDeviceFailure.decoding
            case .rateLimited: return OnDeviceFailure.rateLimited
            case .concurrentRequests: return OnDeviceFailure.busy
            case .refusal: return OnDeviceFailure.refusal
            default: return OnDeviceFailure.other
            }
        }
        #if compiler(>=6.4)
        if #available(macOS 27.0, *), let model = error as? LanguageModelError {
            switch model {
            case .contextSizeExceeded: return OnDeviceFailure.contextExceeded
            case .guardrailViolation: return OnDeviceFailure.guardrail
            case .refusal: return OnDeviceFailure.refusal
            case .unsupportedLanguageOrLocale: return OnDeviceFailure.unsupportedLanguage
            case .rateLimited: return OnDeviceFailure.rateLimited
            default: return OnDeviceFailure.other
            }
        }
        #endif
        return OnDeviceFailure.other
    }
}
#else
/// Without the framework in the SDK there is no model to ask.
struct FoundationModelsEngine: OnDeviceEngine {
    func stream(_ request: OnDeviceRequest) -> AsyncThrowingStream<OnDevicePartialDeck, Error> {
        AsyncThrowingStream { $0.finish(throwing: OnDeviceFailure.assetsUnavailable) }
    }
}
#endif

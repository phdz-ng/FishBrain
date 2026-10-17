import Foundation

/// A guess at how many tokens a request will use, for the cost shown before generating. OpenAI has no
/// call that counts tokens, so this works from what is known: the pages of PDF (OpenAI reads the text and
/// an image of each page), the pictures, and the length of the text. It is a range and it says "about".
enum OpenAIInputEstimate {
    /// A page of PDF: its text plus a picture of the page.
    static let tokensPerPDFPage = 800...2500
    /// A picture, already scaled to at most 2000 px.
    static let tokensPerImage = 500...2500
    /// Text runs from about 3 characters a token (code, other languages) to about 5 (plain English).
    static let charactersPerToken = (low: 5.0, high: 3.0)

    static func tokens(for request: GenerationRequest) -> (low: Int, high: Int) {
        var low = 0, high = 0
        var characters = GenerationPrompt.system.count
        for part in GenerationPrompt.parts(for: request) {
            switch part {
            case .pdf(let pdf):
                low += pdf.pageCount * tokensPerPDFPage.lowerBound
                high += pdf.pageCount * tokensPerPDFPage.upperBound
            case .image:
                low += tokensPerImage.lowerBound
                high += tokensPerImage.upperBound
            case .text(let text):
                characters += text.count
            }
        }
        low += Int((Double(characters) / charactersPerToken.low).rounded(.up))
        high += Int((Double(characters) / charactersPerToken.high).rounded(.up))
        return (low, high)
    }
}

/// Makes cards with OpenAI, over raw HTTP (there is no official Swift SDK): `POST /v1/responses` with a
/// JSON schema as the output format, streamed, so each card can be shown as it is written.
///
/// Built for one run, with the chosen model. OpenAI's model list says nothing about what a model can do,
/// so a model that can't take files, pictures or structured output only shows itself by answering 400; that
/// is `.modelCantMakeCards`, and the model is remembered in `unsupported` for the session. The key is only
/// ever sent to api.openai.com, in a header.
struct OpenAICardGenerator: CardGenerator {
    var apiKey: String
    var model: AIModel
    var transport: StreamingTransport = SystemStreamingTransport.transport
    /// How long to wait before asking again after the service said it was busy.
    var retryDelay: TimeInterval = 2
    var unsupported: UnsupportedModels = .shared

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            // Building the body (base64 of a big PDF) is real work: keep it off the caller's thread.
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

    private func run(_ request: GenerationRequest, _ continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async throws {
        let builder = OpenAIRequestBuilder(modelID: model.id)
        var waitedForBusy = false
        while true {
            try Task.checkCancellation()
            let response = try await open(builder.urlRequest(for: request, apiKey: apiKey))
            if (200..<300).contains(response.status) {
                try await read(response, into: continuation)
                return
            }
            let body = await response.errorBody()
            if OpenAIErrors.isRetryable(status: response.status), !waitedForBusy {
                waitedForBusy = true
                try await Task.sleep(nanoseconds: UInt64(max(retryDelay, 0) * 1_000_000_000))
                continue
            }
            let error = OpenAIErrors.error(status: response.status, body: body, retryAfter: response.headers["retry-after"].flatMap(TimeInterval.init))
            if error == .modelCantMakeCards { unsupported.mark(model.id, provider: .openAI) }
            throw error
        }
    }

    private func open(_ urlRequest: URLRequest) async throws -> StreamingHTTPResponse {
        do {
            return try await transport(urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw GenerationError.network
        }
    }

    private func read(_ response: StreamingHTTPResponse, into continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async throws {
        let reader = OpenAIStreamReader()
        do {
            for try await line in response.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                for event in try reader.handle(payload: payload) { continuation.yield(event) }
                if reader.isStopped { break }
            }
        } catch let error as GenerationError {
            throw error // the stream said it failed; the cards already sent stay
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw GenerationError.network
        }
        let ending = reader.finish()
        for event in ending.events { continuation.yield(event) }
        if let error = ending.error { throw error }
    }

    // MARK: Cost

    /// What this request is expected to cost, as a range, worked out from the size of what is sent (OpenAI
    /// can't count tokens ahead of time) and the model's price. Nil when the price isn't known. Nothing is
    /// sent; it is `async throws` only to sit beside the Anthropic one.
    func estimateCost(for request: GenerationRequest) async throws -> CostEstimate? {
        guard let price = AIPricing.price(for: model.id) else { return nil }
        let tokens = OpenAIInputEstimate.tokens(for: request)
        return CostEstimate(inputTokens: tokens.low, highInputTokens: tokens.high, cardCount: request.cardCount, price: price)
    }
}

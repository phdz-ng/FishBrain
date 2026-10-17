import Foundation

/// The answer to a request that streams: the status and headers now, the body as lines as it arrives.
struct StreamingHTTPResponse: Sendable {
    var status: Int
    /// Header names in lower case.
    var headers: [String: String]
    var lines: AsyncThrowingStream<String, Error>
}

/// Sends a request and returns its answer as it arrives. Tests supply their own, so nothing goes online.
typealias StreamingTransport = @Sendable (URLRequest) async throws -> StreamingHTTPResponse

enum SystemStreamingTransport {
    /// A pause this long between two pieces of the answer (the server sends a `ping` every so often) means
    /// the connection is lost. Longer than the model list's, because reading a big PDF takes a while.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static let transport = transport(using: session)

    /// Tests pass a session whose answers are stubbed.
    static func transport(using session: URLSession) -> StreamingTransport {
        { request in
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
            }
            // `lines` leaves out empty lines, which is fine: only the `data:` lines are read.
            let lines = AsyncThrowingStream<String, Error> { continuation in
                let task = Task {
                    do {
                        for try await line in bytes.lines { continuation.yield(line) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return StreamingHTTPResponse(status: http.statusCode, headers: headers, lines: lines)
        }
    }

    /// For `count_tokens`, which reads the whole request before it answers.
    static let countTransport: HTTPTransport = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// What a run is expected to cost, as a range, before it is sent.
struct CostEstimate: Equatable, Sendable {
    /// The input is counted exactly when the provider can count it (then low and high are the same) and
    /// guessed from the size of the material when it can't.
    var inputTokens: Int
    var highInputTokens: Int
    var lowOutputTokens: Int
    var highOutputTokens: Int
    var low: Double
    var high: Double

    /// Cards are about this many tokens each; the range allows for shorter and longer ones.
    static let outputTokensPerCard = 60
    static let lowFactor = 0.75
    static let highFactor = 1.5

    init(inputTokens: Int, highInputTokens: Int? = nil, cardCount: Int, price: ModelPrice) {
        self.inputTokens = inputTokens
        self.highInputTokens = max(highInputTokens ?? inputTokens, inputTokens)
        let expected = Double(max(cardCount, 0) * Self.outputTokensPerCard)
        lowOutputTokens = Int((expected * Self.lowFactor).rounded())
        highOutputTokens = Int((expected * Self.highFactor).rounded())
        low = price.cost(inputTokens: inputTokens, outputTokens: lowOutputTokens)
        high = price.cost(inputTokens: self.highInputTokens, outputTokens: highOutputTokens)
    }

    /// "about $0.20–$0.30 (estimate · prices updated 8 Oct 2026)"
    func line(locale: Locale = .current) -> String {
        AIPricing.costRangeLine(low, high, locale: locale)
    }
}

extension StreamingHTTPResponse {
    /// An error answer's body, read in full (they are short; the cap is for a server that isn't one of ours).
    func errorBody() async -> String {
        var text = ""
        do {
            for try await line in lines {
                text += (text.isEmpty ? "" : "\n") + line
                if text.utf8.count > 64 * 1024 { break }
            }
        } catch {}
        return text
    }
}

/// Makes cards with Claude, over raw HTTP (there is no official Swift SDK): `POST /v1/messages` with a
/// JSON schema as the output format, streamed, so each card can be shown as it is written.
///
/// Built for one run, with the chosen model as the model list describes it; the body follows what that
/// model can do (`AnthropicCapabilities`). The key is only ever sent to api.anthropic.com, in a header.
struct AnthropicCardGenerator: CardGenerator {
    var apiKey: String
    var model: AIModel
    var transport: StreamingTransport = SystemStreamingTransport.transport
    var countTransport: HTTPTransport = SystemStreamingTransport.countTransport
    /// How long to wait before asking again after the service said it was busy.
    var retryDelay: TimeInterval = 2

    private var capabilities: AnthropicCapabilities { AnthropicCapabilities(model: model) }

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

    // MARK: Messages

    private func run(_ request: GenerationRequest, _ continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async throws {
        var useFallbacks = true
        var waitedForBusy = false
        while true {
            try Task.checkCancellation()
            let builder = AnthropicRequestBuilder(capabilities: capabilities, useFallbacks: useFallbacks)
            let response = try await open(builder.messagesRequest(for: request, apiKey: apiKey))
            if (200..<300).contains(response.status) {
                try await read(response, into: continuation)
                return
            }
            let body = await response.errorBody()
            if response.status == 400, builder.useFallbacks, AnthropicErrors.mentionsFallbacks(body) {
                useFallbacks = false // this model or account doesn't take it: once more without
                continue
            }
            if AnthropicErrors.isRetryable(status: response.status), !waitedForBusy {
                waitedForBusy = true
                try await Task.sleep(nanoseconds: UInt64(max(retryDelay, 0) * 1_000_000_000))
                continue
            }
            throw AnthropicErrors.error(status: response.status, body: body, retryAfter: response.headers["retry-after"].flatMap(TimeInterval.init))
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
        let reader = AnthropicStreamReader()
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

    /// What this request is expected to cost: the input counted by Anthropic (`count_tokens`, same model,
    /// system, messages and output config), the output at about 60 tokens a card. Nil when the model's
    /// price isn't known, and then nothing is sent. Throws `GenerationError` like a run does.
    func estimateCost(for request: GenerationRequest) async throws -> CostEstimate? {
        guard let price = AIPricing.price(for: model.id) else { return nil }
        let urlRequest = try AnthropicRequestBuilder(capabilities: capabilities).countTokensRequest(for: request, apiKey: apiKey)
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await countTransport(urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw GenerationError.network
        }
        guard (200..<300).contains(response.statusCode) else {
            let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw AnthropicErrors.error(status: response.statusCode, body: String(decoding: data, as: UTF8.self), retryAfter: retryAfter)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tokens = root["input_tokens"] as? Int else {
            throw GenerationError.badResponse
        }
        return CostEstimate(inputTokens: tokens, cardCount: request.cardCount, price: price)
    }
}

import Foundation

/// What FishBrain sends to a given Anthropic model, worked out from what the model list says it can do
/// (FLAS-45 keeps that list). Every difference between models lives here, so the request code has no
/// model names in it.
struct AnthropicCapabilities: Equatable, Sendable {
    /// Models that can rerun a refused request on another model inside the same call. Keep this list in
    /// one place; a model not on it never gets `fallbacks`.
    static let fallbackModelIDs: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
    static let fallbackBetaHeader = "server-side-fallback-2026-07-01"
    /// No more than this is asked for, whatever the model could write.
    static let maxTokensCeiling = 64_000
    /// Models with a smaller context window than this take fewer pages of PDF.
    static let largeContextWindow = 1_000_000
    static let smallContextMaxPDFPages = 100

    var modelID: String
    var maxTokens: Int
    /// `low` or `medium` when the model takes `output_config.effort`; nil when it doesn't say so (some
    /// older models reject the setting).
    var effort: String?
    var acceptsImages: Bool
    var supportsFallbacks: Bool
    var maxPDFPages: Int

    init(model: AIModel) {
        modelID = model.id
        maxTokens = min(Self.maxTokensCeiling, model.maxOutputTokens ?? Self.maxTokensCeiling)
        effort = model.supportsEffort == true ? (model.id.lowercased().contains("haiku") ? "low" : "medium") : nil
        acceptsImages = model.supportsImages != false
        supportsFallbacks = Self.fallbackModelIDs.contains(model.id)
        maxPDFPages = model.maxInputTokens.map { $0 < Self.largeContextWindow ? Self.smallContextMaxPDFPages : SourceLimits.maxPDFPages }
            ?? SourceLimits.maxPDFPages
    }
}

/// Builds the requests to the Messages API. Pure: nothing here goes online, so each body can be checked as
/// text. The body is `OrderedJSON` because the schema's property order has to reach the model unchanged.
struct AnthropicRequestBuilder: Sendable {
    static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let countTokensURL = URL(string: "https://api.anthropic.com/v1/messages/count_tokens")!

    var capabilities: AnthropicCapabilities
    /// Ask for `fallbacks: "default"`. Only honoured for models that support it.
    var useFallbacks: Bool

    init(capabilities: AnthropicCapabilities, useFallbacks: Bool = true) {
        self.capabilities = capabilities
        self.useFallbacks = useFallbacks && capabilities.supportsFallbacks
    }

    /// Whether this request can be sent to this model at all.
    func validate(_ request: GenerationRequest) throws {
        if !capabilities.acceptsImages, request.sources.contains(where: { if case .image = $0 { true } else { false } }) {
            throw GenerationError.imagesNotSupported
        }
        if request.totalPDFPages > capabilities.maxPDFPages || request.sizeProblem != nil {
            throw GenerationError.tooLarge
        }
    }

    // MARK: Bodies

    /// The whole content of the one user message: documents and pictures, then text, then the instructions
    /// of this run. Plain text sources go in as `text` blocks.
    static func content(for request: GenerationRequest) -> OrderedJSON {
        .array(GenerationPrompt.parts(for: request).map { part in
            switch part {
            case .pdf(let pdf):
                .object([
                    "type": .string("document"),
                    "source": .object([
                        "type": .string("base64"),
                        "media_type": .string("application/pdf"),
                        "data": .string(pdf.data.base64EncodedString()),
                    ]),
                ])
            case .image(let image):
                .object([
                    "type": .string("image"),
                    "source": .object([
                        "type": .string("base64"),
                        "media_type": .string(image.mediaType),
                        "data": .string(image.data.base64EncodedString()),
                    ]),
                ])
            case .text(let text):
                .object(["type": .string("text"), "text": .string(text)])
            }
        })
    }

    private var outputConfig: OrderedJSON {
        var members: [OrderedJSON.Member] = []
        if let effort = capabilities.effort { members.append(.init(key: "effort", value: .string(effort))) }
        members.append(.init(key: "format", value: .object([
            "type": .string("json_schema"),
            "schema": CardSchema.schema,
        ])))
        return .object(members)
    }

    private func messages(_ content: OrderedJSON) -> OrderedJSON {
        .array([.object(["role": .string("user"), "content": content])])
    }

    /// The body of `POST /v1/messages`. Never has `thinking`, `temperature`, `top_p`, `top_k`, `citations`
    /// or an assistant message to continue: current models turn those down with a 400.
    func messagesBody(for request: GenerationRequest) throws -> OrderedJSON {
        try validate(request)
        var members: [OrderedJSON.Member] = [
            .init(key: "model", value: .string(capabilities.modelID)),
            .init(key: "max_tokens", value: .int(capabilities.maxTokens)),
            .init(key: "stream", value: .bool(true)),
        ]
        if useFallbacks { members.append(.init(key: "fallbacks", value: .string("default"))) }
        members += [
            .init(key: "system", value: .string(GenerationPrompt.system)),
            .init(key: "output_config", value: outputConfig),
            .init(key: "messages", value: messages(Self.content(for: request))),
        ]
        return .object(members)
    }

    /// The body of `POST /v1/messages/count_tokens`: the same model, system, output config and messages,
    /// without `max_tokens`, `stream` or `fallbacks`.
    func countTokensBody(for request: GenerationRequest) throws -> OrderedJSON {
        try validate(request)
        return .object([
            "model": .string(capabilities.modelID),
            "system": .string(GenerationPrompt.system),
            "output_config": outputConfig,
            "messages": messages(Self.content(for: request)),
        ])
    }

    // MARK: URL requests

    func messagesRequest(for request: GenerationRequest, apiKey: String) throws -> URLRequest {
        var urlRequest = Self.baseRequest(url: Self.messagesURL, apiKey: apiKey, body: try messagesBody(for: request).data)
        if useFallbacks { urlRequest.setValue(AnthropicCapabilities.fallbackBetaHeader, forHTTPHeaderField: "anthropic-beta") }
        return urlRequest
    }

    func countTokensRequest(for request: GenerationRequest, apiKey: String) throws -> URLRequest {
        Self.baseRequest(url: Self.countTokensURL, apiKey: apiKey, body: try countTokensBody(for: request).data)
    }

    /// The key goes in a header and nowhere else: never in the URL, a log or an error.
    private static func baseRequest(url: URL, apiKey: String, body: Data) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(AIModelClient.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = body
        return urlRequest
    }
}

/// Anthropic's error answers, turned into `GenerationError`.
enum AnthropicErrors {
    /// `{"type":"error","error":{"type":"overloaded_error","message":"..."}}`
    struct Body: Equatable, Sendable {
        var type: String?
        var message: String?
    }

    static func parse(_ text: String) -> Body {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return Body() }
        return Body(type: error["type"] as? String, message: error["message"] as? String)
    }

    /// A 400 that is about `fallbacks`: the model or the account doesn't take it, so ask again without.
    static func mentionsFallbacks(_ text: String) -> Bool {
        (parse(text).message ?? text).lowercased().contains("fallbacks")
    }

    /// Statuses that are worth asking again after a short wait.
    static func isRetryable(status: Int) -> Bool { [500, 503, 529].contains(status) }

    static func error(status: Int, body: String, retryAfter: TimeInterval?) -> GenerationError {
        switch status {
        case 401: return .invalidKey
        case 403: return .modelForbidden
        case 404: return .modelUnavailable
        case 413: return .tooLarge
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 500..<600: return .overloaded
        case 400:
            let message = (parse(body).message ?? "").lowercased()
            return message.contains("too long") || message.contains("too large") ? .tooLarge : .badResponse
        default: return .badResponse
        }
    }

    /// An `error` event in the middle of a stream names its kind instead of a status.
    static func error(streamType: String?) -> GenerationError {
        switch streamType {
        case "authentication_error": .invalidKey
        case "permission_error": .modelForbidden
        case "not_found_error": .modelUnavailable
        case "request_too_large": .tooLarge
        case "rate_limit_error": .rateLimited(retryAfter: nil)
        case "api_error", "overloaded_error": .overloaded
        default: .badResponse
        }
    }
}

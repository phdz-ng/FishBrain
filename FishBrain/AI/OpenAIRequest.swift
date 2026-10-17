import Foundation

/// Models a provider has turned down for this kind of request, kept for the session so the picker can say
/// so and the composer doesn't offer them again. OpenAI's model list says nothing about what a model can
/// do, so this is learned from a 400.
final class UnsupportedModels: @unchecked Sendable {
    static let shared = UnsupportedModels()

    private let lock = NSLock()
    private var keys: Set<String> = []

    private func key(_ id: String, _ provider: AIProvider) -> String { "\(provider.rawValue):\(id)" }

    func mark(_ id: String, provider: AIProvider) { lock.withLock { _ = keys.insert(key(id, provider)) } }
    func contains(_ id: String, provider: AIProvider) -> Bool { lock.withLock { keys.contains(key(id, provider)) } }
    func reset() { lock.withLock { keys.removeAll() } }
}

/// Builds the request to OpenAI's Responses API (not Chat Completions, which only takes PDFs and has no file
/// URLs). Pure: nothing here goes online, so each body can be checked as text. The body is `OrderedJSON`
/// because the schema's property order has to reach the model unchanged.
struct OpenAIRequestBuilder: Sendable {
    static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    static let schemaName = "flashcard_deck"
    static let maxOutputTokens = 32_000

    var modelID: String

    /// Whether this can be sent: not too heavy, not too many pages. (OpenAI takes files under 50 MB each and
    /// 50 MB in all; `sizeProblem` keeps under 30 MB.)
    func validate(_ request: GenerationRequest) throws {
        if request.sizeProblem != nil { throw GenerationError.tooLarge }
    }

    /// Documents and pictures first, then text, then the instructions of this run.
    static func content(for request: GenerationRequest) -> OrderedJSON {
        .array(GenerationPrompt.parts(for: request).map { part in
            switch part {
            case .pdf(let pdf):
                .object([
                    "type": .string("input_file"),
                    "filename": .string(pdf.filename.isEmpty ? "document.pdf" : pdf.filename),
                    "file_data": .string("data:application/pdf;base64," + pdf.data.base64EncodedString()),
                ])
            case .image(let image):
                .object([
                    "type": .string("input_image"),
                    "image_url": .string("data:\(image.mediaType);base64," + image.data.base64EncodedString()),
                    "detail": .string("auto"),
                ])
            case .text(let text):
                .object(["type": .string("input_text"), "text": .string(text)])
            }
        })
    }

    /// The body of `POST /v1/responses`. `store: false` so OpenAI doesn't keep the response for later
    /// retrieval (it defaults to true).
    func body(for request: GenerationRequest) throws -> OrderedJSON {
        try validate(request)
        return .object([
            "model": .string(modelID),
            "stream": .bool(true),
            "store": .bool(false),
            "max_output_tokens": .int(Self.maxOutputTokens),
            "instructions": .string(GenerationPrompt.system),
            "input": .array([.object(["role": .string("user"), "content": Self.content(for: request)])]),
            "text": .object([
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string(Self.schemaName),
                    "strict": .bool(true),
                    "schema": CardSchema.schema,
                ]),
            ]),
        ])
    }

    /// The key goes in a header and nowhere else: never in the URL, a log or an error.
    func urlRequest(for request: GenerationRequest, apiKey: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: Self.responsesURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try body(for: request).data
        return urlRequest
    }
}

/// OpenAI's error answers, turned into `GenerationError`.
enum OpenAIErrors {
    /// `{"error":{"message":"...","type":"invalid_request_error","param":"text.format","code":"..."}}`
    struct Body: Equatable, Sendable {
        var message: String?
        var type: String?
        var param: String?
        var code: String?
    }

    static func parse(_ text: String) -> Body {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return Body() }
        return Body(
            message: error["message"] as? String, type: error["type"] as? String,
            param: error["param"] as? String, code: error["code"] as? String
        )
    }

    /// Any 5xx is worth asking again after a short wait.
    static func isRetryable(status: Int) -> Bool { (500..<600).contains(status) }

    static func isOutOfCredit(_ body: Body) -> Bool { body.code == "insufficient_quota" || body.type == "insufficient_quota" }

    /// A 400 that is about the model or one of the request's parameters (a model that can't take files,
    /// pictures or structured output says so this way), as opposed to the material being too big.
    static func isAboutModelOrParameter(_ body: Body) -> Bool {
        let codes: Set<String> = ["unsupported_parameter", "unsupported_value", "unknown_parameter", "model_not_found", "invalid_model", "model_not_supported"]
        if let code = body.code, codes.contains(code) { return true }
        if body.param != nil { return true }
        let message = (body.message ?? "").lowercased()
        return ["does not support", "not supported", "unsupported", "unknown parameter", "unrecognized request argument", "model"].contains { message.contains($0) }
    }

    static func error(status: Int, body text: String, retryAfter: TimeInterval?) -> GenerationError {
        let body = parse(text)
        switch status {
        case 401: return .invalidKey
        case 403, 404: return .modelForbidden
        case 413: return .tooLarge
        case 429: return isOutOfCredit(body) ? .outOfCredit : .rateLimited(retryAfter: retryAfter)
        case 500..<600: return .overloaded
        case 400:
            let message = (body.message ?? "").lowercased()
            if body.code == "context_length_exceeded" || message.contains("too long") || message.contains("too large") || message.contains("context length") {
                return .tooLarge
            }
            return error(code: body.code) ?? (isAboutModelOrParameter(body) ? .modelCantMakeCards : .badResponse)
        default: return .badResponse
        }
    }

    /// A failure inside the stream (`response.failed`, or an `error` event) names an error code instead of a
    /// status. Nil when the code says nothing in particular.
    static func error(code: String?) -> GenerationError? {
        switch code {
        case "rate_limit_exceeded": .rateLimited(retryAfter: nil)
        case "insufficient_quota": .outOfCredit
        case "server_error": .overloaded
        case "invalid_prompt", "bio_policy", "misalignment_policy_violation", "image_content_policy_violation": .refused
        case "image_too_large", "image_file_too_large", "context_length_exceeded": .tooLarge
        case "model_not_found": .modelForbidden
        default: nil
        }
    }

    static func streamError(code: String?) -> GenerationError { error(code: code) ?? .badResponse }
}

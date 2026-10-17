import Foundation

/// A model a key can use, as the provider's list describes it.
struct AIModel: Codable, Equatable, Hashable, Identifiable, Sendable {
    var provider: AIProvider
    var id: String
    var displayName: String
    var created: Date?
    /// What Anthropic says it can do; nil where the provider's list doesn't say (OpenAI's doesn't).
    var supportsImages: Bool?
    var supportsStructuredOutput: Bool?
    var supportsEffort: Bool?
    var maxInputTokens: Int?
    var maxOutputTokens: Int?

    /// Reads "text and PDF only" in the picker when the model is known not to take pictures.
    var isTextAndPDFOnly: Bool { supportsImages == false }

    /// How the picker words a model: "Claude Opus 5.5 · Recommended · text and PDF only · price not known".
    var pickerTitle: String {
        var parts = [displayName]
        if id == provider.recommendedModelID { parts.append("Recommended") }
        if isTextAndPDFOnly { parts.append("text and PDF only") }
        if AIPricing.price(for: id) == nil { parts.append("price not known") }
        return parts.joined(separator: " · ")
    }
}

extension AIModel {
    /// The model that comes with the Mac, as the rest of the app sees a model. It has no price and no list to pick from.
    static func onDevice(_ status: OnDeviceStatus) -> AIModel {
        AIModel(
            provider: .appleIntelligence, id: AIProvider.onDeviceModelID, displayName: "Apple Intelligence", created: nil,
            supportsImages: status.supportsImages, supportsStructuredOutput: true, supportsEffort: false,
            maxInputTokens: status.contextSize, maxOutputTokens: nil
        )
    }
}

/// Why asking a provider for something failed, in words a person can act on.
enum AIError: Error, Equatable, Sendable {
    /// 401 or 403: the key isn't valid, or isn't allowed to do this.
    case rejected
    case network
    case rateLimited
    case unavailable
    case unexpected(status: Int)
    case badResponse

    var message: String {
        switch self {
        case .rejected: "This key was rejected"
        case .network: "No network connection"
        case .rateLimited: "Too many requests. Try again in a moment."
        case .unavailable: "The service isn't answering. Try again in a moment."
        case .unexpected(let status): "Something went wrong (error \(status))."
        case .badResponse: "The answer wasn't what FishBrain expected."
        }
    }
}

/// Which of a provider's models to list, in one place so it can be tested.
enum ModelFilter {
    /// Anthropic's list says what each model can do. Cards come back as JSON that matches a schema, so only
    /// models that support structured output are listed.
    static func anthropicUsable(_ models: [AIModel]) -> [AIModel] {
        models.filter { $0.supportsStructuredOutput == true }
    }

    /// Words that mark a model as something else: audio, speech, images, search, embeddings and so on.
    static let openAIExcludedWords = ["audio", "realtime", "transcribe", "tts", "image", "search", "embedding", "moderation"]

    /// OpenAI's list is only ids, and has everything in it. By default: `gpt-` models that aren't audio,
    /// image or search ones, newest first. `showAll` lists everything, newest first.
    static func openAI(_ models: [AIModel], showAll: Bool) -> [AIModel] {
        let sorted = models.sorted { ($0.created ?? .distantPast, $1.id) > ($1.created ?? .distantPast, $0.id) }
        guard !showAll else { return sorted }
        return sorted.filter { model in
            let id = model.id.lowercased()
            return id.hasPrefix("gpt-") && !openAIExcludedWords.contains { id.contains($0) }
        }
    }

    /// What the picker lists for a provider.
    static func visible(_ models: [AIModel], for provider: AIProvider, showAllOpenAI: Bool) -> [AIModel] {
        switch provider {
        case .anthropic: anthropicUsable(models)
        case .openAI: openAI(models, showAll: showAllOpenAI)
        case .appleIntelligence: models
        }
    }
}

/// The two providers' answers to "which models can this key use?".
enum ModelListParser {
    private struct AnthropicPage: Decodable {
        struct Item: Decodable {
            struct Capability: Decodable { var supported: Bool? }
            struct Capabilities: Decodable {
                var imageInput: Capability?
                var structuredOutputs: Capability?
                var effort: Capability?
            }
            var id: String
            var displayName: String?
            var createdAt: String?
            var maxInputTokens: Int?
            var maxTokens: Int?
            var capabilities: Capabilities?
        }
        var data: [Item]
        var hasMore: Bool?
        var lastId: String?
    }

    private struct OpenAIList: Decodable {
        struct Item: Decodable {
            var id: String
            var created: Int?
        }
        var data: [Item]
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// One page of Anthropic's list, and the id to ask for the next page with (nil on the last page).
    static func anthropic(_ data: Data) throws -> (models: [AIModel], nextAfterID: String?) {
        let page = try decoder.decode(AnthropicPage.self, from: data)
        let models = page.data.map { item in
            AIModel(
                provider: .anthropic, id: item.id, displayName: item.displayName ?? item.id,
                created: item.createdAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                supportsImages: item.capabilities?.imageInput?.supported,
                supportsStructuredOutput: item.capabilities?.structuredOutputs?.supported,
                supportsEffort: item.capabilities?.effort?.supported,
                maxInputTokens: item.maxInputTokens, maxOutputTokens: item.maxTokens
            )
        }
        return (models, page.hasMore == true ? page.lastId : nil)
    }

    static func openAI(_ data: Data) throws -> [AIModel] {
        try decoder.decode(OpenAIList.self, from: data).data.map { item in
            AIModel(
                provider: .openAI, id: item.id, displayName: item.id,
                created: item.created.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
    }
}

/// Sends a request and returns the answer. Tests supply their own, so nothing goes online.
typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

enum SystemTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static let transport: HTTPTransport = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Asks a provider which models a key can use. The key goes in a header and nowhere else: it is never
/// put in a URL, a log or an error.
struct AIModelClient: Sendable {
    var transport: HTTPTransport = SystemTransport.transport

    static let anthropicVersion = "2023-06-01"
    /// Anthropic lists models a page at a time; this is a stop in case a server keeps saying there is more.
    static let maxPages = 20

    func models(for provider: AIProvider, apiKey: String) async throws -> [AIModel] {
        switch provider {
        case .anthropic: try await anthropicModels(apiKey: apiKey)
        case .openAI: try await openAIModels(apiKey: apiKey)
        case .appleIntelligence: []
        }
    }

    // MARK: Anthropic

    func anthropicRequest(apiKey: String, afterID: String?) -> URLRequest {
        var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
        components.queryItems = [URLQueryItem(name: "limit", value: "100")] + (afterID.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }

    private func anthropicModels(apiKey: String) async throws -> [AIModel] {
        var all: [AIModel] = []
        var after: String?
        for _ in 0..<Self.maxPages {
            let data = try await send(anthropicRequest(apiKey: apiKey, afterID: after))
            let page: (models: [AIModel], nextAfterID: String?)
            do { page = try ModelListParser.anthropic(data) } catch { throw AIError.badResponse }
            all += page.models
            guard let next = page.nextAfterID else { return all }
            after = next
        }
        return all
    }

    // MARK: OpenAI

    func openAIRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func openAIModels(apiKey: String) async throws -> [AIModel] {
        let data = try await send(openAIRequest(apiKey: apiKey))
        do { return try ModelListParser.openAI(data) } catch { throw AIError.badResponse }
    }

    // MARK: Sending

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIError.network
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw AIError.rejected
        case 429: throw AIError.rateLimited
        case 500..<600: throw AIError.unavailable
        default: throw AIError.unexpected(status: response.statusCode)
        }
    }
}

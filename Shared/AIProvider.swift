import Foundation

/// Who writes the cards. Two companies, where people bring their own key, and the model that comes with the Mac
/// (Apple Intelligence), which needs no key, goes nowhere and costs nothing.
enum AIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropic, openAI, appleIntelligence

    var id: String { rawValue }

    /// The ones that are a company's service: a key, a model list, a price and the network.
    static let cloud: [AIProvider] = [.anthropic, .openAI]

    var isOnDevice: Bool { self == .appleIntelligence }
    var needsKey: Bool { !isOnDevice }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .appleIntelligence: "Apple Intelligence"
        }
    }

    /// The model used until the person picks another (when the key can use it).
    var recommendedModelID: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openAI: "gpt-6-astra"
        case .appleIntelligence: Self.onDeviceModelID
        }
    }

    /// The one model Apple Intelligence has: the system's.
    static let onDeviceModelID = "apple-intelligence-on-device"

    /// Where a key is made, shown as text. (Empty for the on-device model, which has none.)
    var keysPage: String {
        switch self {
        case .anthropic: "console.anthropic.com"
        case .openAI: "platform.openai.com"
        case .appleIntelligence: ""
        }
    }

    /// Where the current prices are, shown as text.
    var pricingPage: String {
        switch self {
        case .anthropic: "anthropic.com/pricing"
        case .openAI: "openai.com/api/pricing"
        case .appleIntelligence: ""
        }
    }

    /// The Keychain service the key is stored under.
    var keychainService: String { "com.fishbrain.ai.\(rawValue.lowercased())" }

    /// What keys start with, for a hint in the field.
    var keyHint: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openAI: "sk-…"
        case .appleIntelligence: ""
        }
    }
}

/// The choices made in Settings > AI. Not the keys: those live only in the Keychain.
struct AISettings: Codable, Equatable, Sendable {
    /// The provider "Generate" uses. Nil until a key has been added.
    var provider: AIProvider?
    var anthropicModel: String?
    var openAIModel: String?
    /// How many cards a run asks for by default.
    var cardsPerRun = AISettings.defaultCardsPerRun
    /// "Show an estimated cost before generating".
    var showsCostEstimate = true
    /// OpenAI's list has chat models mixed with embeddings, audio and so on; by default only the likely ones show.
    var showsAllOpenAIModels = false

    static let defaultCardsPerRun = 20
    static let cardsPerRunChoices = [10, 20, 30, 50]

    init(
        provider: AIProvider? = nil, anthropicModel: String? = nil, openAIModel: String? = nil,
        cardsPerRun: Int = AISettings.defaultCardsPerRun, showsCostEstimate: Bool = true, showsAllOpenAIModels: Bool = false
    ) {
        self.provider = provider
        self.anthropicModel = anthropicModel
        self.openAIModel = openAIModel
        self.cardsPerRun = max(cardsPerRun, 1)
        self.showsCostEstimate = showsCostEstimate
        self.showsAllOpenAIModels = showsAllOpenAIModels
    }

    /// Missing keys (an older file) take their defaults; an unknown provider reads as none.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? container.decodeIfPresent(String.self, forKey: .provider)).flatMap { $0 }.flatMap(AIProvider.init(rawValue:))
        anthropicModel = try container.decodeIfPresent(String.self, forKey: .anthropicModel)
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel)
        cardsPerRun = max(try container.decodeIfPresent(Int.self, forKey: .cardsPerRun) ?? Self.defaultCardsPerRun, 1)
        showsCostEstimate = try container.decodeIfPresent(Bool.self, forKey: .showsCostEstimate) ?? true
        showsAllOpenAIModels = try container.decodeIfPresent(Bool.self, forKey: .showsAllOpenAIModels) ?? false
    }

    /// The model chosen for a provider (the on-device one has no choice to make).
    func model(for provider: AIProvider) -> String? {
        switch provider {
        case .anthropic: anthropicModel
        case .openAI: openAIModel
        case .appleIntelligence: AIProvider.onDeviceModelID
        }
    }

    mutating func setModel(_ id: String?, for provider: AIProvider) {
        switch provider {
        case .anthropic: anthropicModel = id
        case .openAI: openAIModel = id
        case .appleIntelligence: break
        }
    }
}

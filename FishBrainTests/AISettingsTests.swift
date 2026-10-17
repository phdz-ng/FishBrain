import XCTest

/// Settings > AI: keys, model lists, prices and the choices made (FLAS-45).

// MARK: - Test doubles

/// Stands in for the network: hands back queued answers and remembers what was asked.
final class FakeAPI: @unchecked Sendable {
    enum Reply {
        case json(Int, String)
        case failure(Error)
    }

    private let lock = NSLock()
    private var replies: [Reply] = []
    private var delay: Duration = .zero
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply] = []) { self.replies = replies }

    func enqueue(_ reply: Reply) { lock.withLock { replies.append(reply) } }
    func setDelay(_ delay: Duration) { lock.withLock { self.delay = delay } }

    var transport: HTTPTransport {
        { [self] request in
            let (reply, wait): (Reply, Duration) = lock.withLock {
                requests.append(request)
                return (replies.isEmpty ? .json(200, #"{"data":[]}"#) : replies.removeFirst(), delay)
            }
            if wait > .zero { try await Task.sleep(for: wait) }
            switch reply {
            case .failure(let error): throw error
            case .json(let status, let body):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
        }
    }
}

enum AIFixtures {
    static func anthropicPage(_ items: [(id: String, name: String, structured: Bool?, images: Bool?)], hasMore: Bool = false, lastID: String? = nil) -> String {
        let models = items.map { item -> String in
            var caps: [String] = []
            if let s = item.structured { caps.append(#""structured_outputs":{"supported":\#(s)}"#) }
            if let i = item.images { caps.append(#""image_input":{"supported":\#(i)}"#) }
            caps.append(#""effort":{"supported":true}"#)
            return #"{"id":"\#(item.id)","display_name":"\#(item.name)","created_at":"2026-08-01T00:00:00Z","max_input_tokens":1000000,"max_tokens":128000,"capabilities":{\#(caps.joined(separator: ","))}}"#
        }.joined(separator: ",")
        return #"{"data":[\#(models)],"has_more":\#(hasMore),"last_id":\#(lastID.map { "\"\($0)\"" } ?? "null")}"#
    }

    static func openAIList(_ items: [(String, Int)]) -> String {
        #"{"object":"list","data":["# + items.map { #"{"id":"\#($0.0)","object":"model","created":\#($0.1),"owned_by":"openai"}"# }.joined(separator: ",") + "]}"
    }

    static let anthropicDefault = anthropicPage([
        ("claude-opus-5-5", "Claude Opus 5.5", true, true),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5", true, true),
        ("claude-old-1", "Claude Old", false, true),
        ("claude-text-1", "Claude Text", true, false),
    ])

    static let openAIDefault = openAIList([
        ("gpt-6-astra", 1_790_000_000), ("gpt-6.1-sol", 1_795_000_000), ("gpt-6-luna", 1_785_000_000),
        ("text-embedding-4", 1_780_000_000), ("gpt-6-audio-preview", 1_788_000_000), ("whisper-2", 1_770_000_000),
        ("gpt-image-2", 1_789_000_000), ("omni-moderation-2", 1_760_000_000),
    ])
}

struct FailingSecretStore: SecretStore {
    func secret(for provider: AIProvider) -> String? { nil }
    func setSecret(_ secret: String, for provider: AIProvider) throws { throw SecretStoreError.keychain(-25293) }
    func removeSecret(for provider: AIProvider) throws { throw SecretStoreError.keychain(-25293) }
}

// MARK: - Keychain

final class KeychainSecretStoreTests: XCTestCase {
    private func makeStore() -> KeychainSecretStore {
        let store = KeychainSecretStore(servicePrefix: "com.fishbrain.tests.\(UUID().uuidString)")
        addTeardownBlock { for provider in AIProvider.cloud { try? store.removeSecret(for: provider) } }
        return store
    }

    func testAKeyRoundTripsThroughTheKeychain() throws {
        let store = makeStore()
        do { try store.setSecret("sk-ant-test-1234567890", for: .anthropic) } catch {
            throw XCTSkip("The Keychain isn't available here: \(error)")
        }
        XCTAssertEqual(store.secret(for: .anthropic), "sk-ant-test-1234567890")
        XCTAssertNil(store.secret(for: .openAI), "each provider has its own entry")
    }

    func testSavingAgainReplacesTheKeyAndRemovingDeletesIt() throws {
        let store = makeStore()
        do { try store.setSecret("first-key-value-0001", for: .openAI) } catch { throw XCTSkip("The Keychain isn't available here") }
        try store.setSecret("second-key-value-0002", for: .openAI)
        XCTAssertEqual(store.secret(for: .openAI), "second-key-value-0002")
        try store.removeSecret(for: .openAI)
        XCTAssertNil(store.secret(for: .openAI))
        XCTAssertNoThrow(try store.removeSecret(for: .openAI), "removing what isn't there is fine")
    }

    func testTheRealServiceNamesAreOnePerProvider() {
        XCTAssertEqual(AIProvider.anthropic.keychainService, "com.fishbrain.ai.anthropic")
        XCTAssertEqual(AIProvider.openAI.keychainService, "com.fishbrain.ai.openai")
    }

    func testTheInMemoryStoreNeverTouchesTheKeychain() throws {
        let store = InMemorySecretStore()
        try store.setSecret("abc", for: .anthropic)
        XCTAssertEqual(store.secret(for: .anthropic), "abc")
        XCTAssertNil(KeychainSecretStore().secret(for: .anthropic) == "abc" ? "leaked" : nil)
        try store.removeSecret(for: .anthropic)
        XCTAssertNil(store.secret(for: .anthropic))
    }
}

// MARK: - The two providers' lists

final class AIModelClientTests: XCTestCase {
    private func client(_ api: FakeAPI) -> AIModelClient { AIModelClient(transport: api.transport) }

    func testAnthropicIsAskedWithTheKeyInAHeaderAndNeverInTheAddress() async throws {
        let api = FakeAPI([.json(200, AIFixtures.anthropicDefault)])
        _ = try await client(api).models(for: .anthropic, apiKey: "sk-ant-secret-key-0001")
        let request = try XCTUnwrap(api.requests.first)
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.url?.path, "/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-secret-key-0001")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertFalse(request.url!.absoluteString.contains("secret"), "never in the URL")
        XCTAssertNil(request.httpBody)
    }

    func testAnthropicsListIsReadWithWhatEachModelCanDo() async throws {
        let api = FakeAPI([.json(200, AIFixtures.anthropicDefault)])
        let models = try await client(api).models(for: .anthropic, apiKey: "k")
        let opus = try XCTUnwrap(models.first { $0.id == "claude-opus-5-5" })
        XCTAssertEqual(opus.displayName, "Claude Opus 5.5")
        XCTAssertEqual(opus.supportsStructuredOutput, true)
        XCTAssertEqual(opus.supportsImages, true)
        XCTAssertEqual(opus.supportsEffort, true)
        XCTAssertEqual(opus.maxInputTokens, 1_000_000)
        XCTAssertEqual(opus.maxOutputTokens, 128_000)
        XCTAssertNotNil(opus.created)
        XCTAssertEqual(models.first { $0.id == "claude-text-1" }?.supportsImages, false)
    }

    func testAnthropicsPagesAreFollowedToTheEnd() async throws {
        let api = FakeAPI([
            .json(200, AIFixtures.anthropicPage([("a", "A", true, true)], hasMore: true, lastID: "a")),
            .json(200, AIFixtures.anthropicPage([("b", "B", true, true)], hasMore: true, lastID: "b")),
            .json(200, AIFixtures.anthropicPage([("c", "C", true, true)], hasMore: false)),
        ])
        let models = try await client(api).models(for: .anthropic, apiKey: "k")
        XCTAssertEqual(models.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(api.requests.count, 3)
        XCTAssertNil(api.requests[0].url?.query?.contains("after_id") == true ? "yes" : nil)
        XCTAssertTrue(api.requests[1].url?.query?.contains("after_id=a") == true)
        XCTAssertTrue(api.requests[2].url?.query?.contains("after_id=b") == true)
    }

    func testAServerThatNeverStopsSayingThereIsMoreIsStopped() async throws {
        let api = FakeAPI((0..<50).map { _ in .json(200, AIFixtures.anthropicPage([("x", "X", true, true)], hasMore: true, lastID: "x")) })
        _ = try await client(api).models(for: .anthropic, apiKey: "k")
        XCTAssertEqual(api.requests.count, AIModelClient.maxPages)
    }

    func testOpenAIIsAskedWithABearerHeader() async throws {
        let api = FakeAPI([.json(200, AIFixtures.openAIDefault)])
        let models = try await client(api).models(for: .openAI, apiKey: "sk-openai-secret-0002")
        let request = try XCTUnwrap(api.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-openai-secret-0002")
        XCTAssertEqual(models.count, 8)
        XCTAssertEqual(models.first { $0.id == "gpt-6-astra" }?.created, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testTheErrorsAreMappedToWhatAPersonCanActOn() async {
        let cases: [(FakeAPI.Reply, AIError)] = [
            (.json(401, "{}"), .rejected),
            (.json(403, "{}"), .rejected),
            (.json(429, "{}"), .rateLimited),
            (.json(500, "{}"), .unavailable),
            (.json(503, "{}"), .unavailable),
            (.json(404, "{}"), .unexpected(status: 404)),
            (.failure(URLError(.notConnectedToInternet)), .network),
            (.failure(URLError(.timedOut)), .network),
            (.json(200, "not json"), .badResponse),
        ]
        for (reply, expected) in cases {
            for provider in AIProvider.cloud {
                do {
                    _ = try await client(FakeAPI([reply])).models(for: provider, apiKey: "k")
                    XCTFail("should throw for \(expected)")
                } catch {
                    XCTAssertEqual(error as? AIError, expected, "\(provider)")
                }
            }
        }
    }

    func testTheMessages() {
        XCTAssertEqual(AIError.rejected.message, "This key was rejected")
        XCTAssertEqual(AIError.network.message, "No network connection")
        XCTAssertFalse(AIError.rateLimited.message.isEmpty)
        XCTAssertTrue(AIError.unexpected(status: 418).message.contains("418"))
    }

    func testAnErrorNeverCarriesTheKey() async {
        let api = FakeAPI([.json(401, #"{"error":{"message":"bad key sk-ant-secret-key-0001"}}"#)])
        do {
            _ = try await client(api).models(for: .anthropic, apiKey: "sk-ant-secret-key-0001")
        } catch {
            XCTAssertFalse("\(error)".contains("secret"))
            XCTAssertFalse((error as? AIError)?.message.contains("secret") ?? false)
        }
    }
}

// MARK: - Which models are listed

final class ModelFilterTests: XCTestCase {
    private func model(_ id: String, created: Int? = nil, structured: Bool? = nil, provider: AIProvider = .openAI) -> AIModel {
        AIModel(provider: provider, id: id, displayName: id, created: created.map { Date(timeIntervalSince1970: TimeInterval($0)) }, supportsStructuredOutput: structured)
    }

    func testAnthropicListsOnlyModelsThatCanReturnJSON() {
        let list = [model("a", structured: true, provider: .anthropic), model("b", structured: false, provider: .anthropic), model("c", structured: nil, provider: .anthropic)]
        XCTAssertEqual(ModelFilter.anthropicUsable(list).map(\.id), ["a"], "unknown counts as no")
    }

    func testOpenAIByDefaultListsLikelyChatModelsNewestFirst() async throws {
        let models = try ModelListParser.openAI(Data(AIFixtures.openAIDefault.utf8))
        XCTAssertEqual(ModelFilter.openAI(models, showAll: false).map(\.id), ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna"])
    }

    func testEachExcludedWordKeepsAModelOut() {
        for word in ["audio", "realtime", "transcribe", "tts", "image", "search"] {
            XCTAssertTrue(ModelFilter.openAI([model("gpt-6-\(word)-x")], showAll: false).isEmpty, word)
        }
        XCTAssertTrue(ModelFilter.openAI([model("o4"), model("whisper-1"), model("text-embedding-3")], showAll: false).isEmpty, "not gpt-")
        XCTAssertEqual(ModelFilter.openAI([model("GPT-6-Astra")], showAll: false).count, 1, "case doesn't matter")
    }

    func testShowAllListsEverythingNewestFirst() {
        let list = [model("old", created: 1), model("new", created: 3), model("gpt-6-audio", created: 2)]
        XCTAssertEqual(ModelFilter.openAI(list, showAll: true).map(\.id), ["new", "gpt-6-audio", "old"])
    }

    func testTheVisibleListFollowsTheProvider() {
        XCTAssertEqual(ModelFilter.visible([model("gpt-6-astra")], for: .openAI, showAllOpenAI: false).count, 1)
        XCTAssertTrue(ModelFilter.visible([model("gpt-6-astra", provider: .anthropic)], for: .anthropic, showAllOpenAI: true).isEmpty, "no structured output known")
    }

    func testThePickerTitles() {
        let opus = AIModel(provider: .anthropic, id: "claude-opus-5-5", displayName: "Claude Opus 5.5", supportsImages: true, supportsStructuredOutput: true)
        XCTAssertEqual(opus.pickerTitle, "Claude Opus 5.5 · Recommended")
        let text = AIModel(provider: .anthropic, id: "claude-text-1", displayName: "Claude Text", supportsImages: false, supportsStructuredOutput: true)
        XCTAssertEqual(text.pickerTitle, "Claude Text · text and PDF only · price not known")
        XCTAssertEqual(AIModel(provider: .openAI, id: "gpt-6-astra", displayName: "gpt-6-astra").pickerTitle, "gpt-6-astra · Recommended")
        XCTAssertTrue(text.isTextAndPDFOnly)
        XCTAssertFalse(AIModel(provider: .openAI, id: "x", displayName: "x").isTextAndPDFOnly, "unknown isn't text-only")
    }
}

// MARK: - Prices

final class AIPricingTests: XCTestCase {
    private let british = Locale(identifier: "en_GB")
    private let american = Locale(identifier: "en_US")

    func testAModelsPriceLine() {
        XCTAssertEqual(AIPricing.priceLine(for: "claude-opus-5-5", locale: british), "$4 / $20 per million tokens (estimate · prices updated 8 Oct 2026)")
        XCTAssertEqual(AIPricing.priceLine(for: "claude-haiku-5-5", locale: british), "$0.10 / $0.50 per million tokens (estimate · prices updated 8 Oct 2026)")
        XCTAssertEqual(AIPricing.priceLine(for: "gpt-6-astra", locale: british), "$10 / $50 per million tokens (estimate · prices updated 8 Oct 2026)")
    }

    func testAModelNotInTheTableHasNoPrice() {
        XCTAssertEqual(AIPricing.priceLine(for: "some-new-model"), "price not known")
        XCTAssertNil(AIPricing.price(for: "some-new-model"))
    }

    func testTheDateFollowsThePersonsLocale() {
        XCTAssertEqual(AIPricing.updatedText(locale: british), "8 Oct 2026")
        XCTAssertEqual(AIPricing.updatedText(locale: american), "Oct 8, 2026")
    }

    func testEveryCostSaysEstimateAndWhenThePricesWereUpdated() {
        for line in [AIPricing.costLine(0.25, locale: british), AIPricing.priceLine(for: "gpt-6.1-sol", locale: british)] {
            XCTAssertTrue(line.contains("estimate"), line)
            XCTAssertTrue(line.contains("prices updated 8 Oct 2026"), line)
        }
        XCTAssertEqual(AIPricing.costLine(0.25, locale: british), "about $0.25 (estimate · prices updated 8 Oct 2026)")
        XCTAssertEqual(AIPricing.costLine(0.21, locale: british), "about $0.21 (estimate · prices updated 8 Oct 2026)")
        XCTAssertEqual(AIPricing.costLine(0.001, locale: british), "less than $0.01 (estimate · prices updated 8 Oct 2026)")
    }

    func testTheFootnoteAndTooltip() {
        XCTAssertEqual(
            AIPricing.footnote(locale: british),
            "Prices last updated 8 Oct 2026 and may have changed since. Your provider's pricing page has the current rates (anthropic.com/pricing, openai.com/api/pricing)."
        )
        XCTAssertTrue(AIPricing.tooltip(locale: british).contains("last updated 8 Oct 2026"))
        XCTAssertTrue(AIPricing.tooltip(locale: british).contains("billing page"))
    }

    func testDollarFormatting() {
        XCTAssertEqual(AIPricing.dollars(4), "$4")
        XCTAssertEqual(AIPricing.dollars(20), "$20")
        XCTAssertEqual(AIPricing.dollars(0.1), "$0.10")
        XCTAssertEqual(AIPricing.dollars(0.5), "$0.50")
    }

    func testACostIsWorkedOutFromTheTokens() throws {
        let price = try XCTUnwrap(AIPricing.price(for: "claude-opus-5-5"))
        // 24 pages, about 60,000 tokens in and 2,000 out.
        XCTAssertEqual(price.cost(inputTokens: 60_000, outputTokens: 2_000), 0.28, accuracy: 0.0001)
        XCTAssertEqual(price.cost(inputTokens: 0, outputTokens: 0), 0)
    }

    func testTheRecommendedModelsAreInTheTable() {
        for provider in AIProvider.cloud {
            XCTAssertNotNil(AIPricing.price(for: provider.recommendedModelID), provider.displayName)
        }
        XCTAssertEqual(AIProvider.anthropic.recommendedModelID, "claude-opus-5-5")
        XCTAssertEqual(AIProvider.openAI.recommendedModelID, "gpt-6-astra")
    }

    func testTheTableMatchesTheDocumentedPrices() {
        XCTAssertEqual(AIPricing.price(for: "claude-sonnet-5-5"), ModelPrice(inputPerMillion: 2, outputPerMillion: 10))
        XCTAssertEqual(AIPricing.price(for: "gpt-6.1-sol"), ModelPrice(inputPerMillion: 2, outputPerMillion: 10))
        XCTAssertEqual(AIPricing.price(for: "gpt-6-luna"), ModelPrice(inputPerMillion: 0.10, outputPerMillion: 0.50))
    }
}

// MARK: - The saved choices

final class AISettingsStorageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try PictureFixtures.tempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testTheDefaults() {
        let ai = AISettings()
        XCTAssertNil(ai.provider)
        XCTAssertEqual(ai.cardsPerRun, 20)
        XCTAssertTrue(ai.showsCostEstimate)
        XCTAssertFalse(ai.showsAllOpenAIModels)
        XCTAssertEqual(AISettings.cardsPerRunChoices, [10, 20, 30, 50])
    }

    func testTheChoicesAreSavedAndAnOlderFileGetsTheDefaults() throws {
        let storage = SettingsStorage(directory: directory)
        var ai = AISettings(provider: .openAI, openAIModel: "gpt-6-astra", cardsPerRun: 30, showsCostEstimate: false, showsAllOpenAIModels: true)
        ai.setModel("claude-opus-5-5", for: .anthropic)
        try storage.save(AppSettings(ai: ai))
        XCTAssertEqual(storage.load().ai, ai)
        XCTAssertEqual(storage.load().ai.model(for: .anthropic), "claude-opus-5-5")

        try Data(#"{"accent":"teal"}"#.utf8).write(to: storage.fileURL)
        XCTAssertEqual(storage.load().ai, AISettings())
    }

    func testAnUnknownProviderReadsAsNone() throws {
        try Data(#"{"ai":{"provider":"mistral","cardsPerRun":10}}"#.utf8).write(to: SettingsStorage(directory: directory).fileURL)
        let ai = SettingsStorage(directory: directory).load().ai
        XCTAssertNil(ai.provider)
        XCTAssertEqual(ai.cardsPerRun, 10)
    }

    func testCardsPerRunIsAtLeastOneAndTheChoicesIncludeAnOddSavedValue() {
        XCTAssertEqual(AISettings(cardsPerRun: 0).cardsPerRun, 1)
        XCTAssertEqual(CardsPerRun.choices(including: 20), [10, 20, 30, 50])
        XCTAssertEqual(CardsPerRun.choices(including: 25), [10, 20, 25, 30, 50])
    }

    @MainActor
    func testTheStoreSavesAChangeAtOnceAndKeepsKeysOutOfTheFile() throws {
        let storage = SettingsStorage(directory: directory)
        let store = SettingsStore(storage: storage, onSaved: {})
        store.ai.provider = .anthropic
        store.ai.cardsPerRun = 50
        XCTAssertEqual(storage.load().ai.provider, .anthropic)
        XCTAssertEqual(storage.load().ai.cardsPerRun, 50)
        let text = try String(contentsOf: storage.fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("sk-"), "no key")
        XCTAssertFalse(text.lowercased().contains("apikey"), "and no field that could hold one")
        XCTAssertFalse(text.lowercased().contains("secret"))
    }
}

// MARK: - Keys, models and choices together

@MainActor
final class AIAccountStoreTests: XCTestCase {
    private var directory: URL!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws { directory = try PictureFixtures.tempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private struct Rig {
        var store: AIAccountStore
        var settings: SettingsStore
        var secrets: InMemorySecretStore
        var api: FakeAPI
    }

    private func makeRig(_ replies: [FakeAPI.Reply] = [], secrets: InMemorySecretStore = InMemorySecretStore()) -> Rig {
        let api = FakeAPI(replies)
        let settings = SettingsStore(storage: SettingsStorage(directory: directory), onSaved: {})
        let store = AIAccountStore(
            secrets: secrets, client: AIModelClient(transport: api.transport),
            cacheStorage: AIModelCacheStorage(directory: directory), settings: settings, clock: { self.now }
        )
        return Rig(store: store, settings: settings, secrets: secrets, api: api)
    }

    // MARK: Adding a key

    func testAddingAKeyChecksItAndShowsItWorks() async {
        let rig = makeRig([.json(200, AIFixtures.anthropicDefault)])
        await rig.store.saveKey("  sk-ant-api03-abcdefghijklmnop3f9a \n", for: .anthropic)
        XCTAssertEqual(rig.store.status(for: .anthropic), .works)
        XCTAssertEqual(rig.secrets.secret(for: .anthropic), "sk-ant-api03-abcdefghijklmnop3f9a", "trimmed")
        XCTAssertEqual(rig.store.maskedKey(for: .anthropic), "sk-ant-•••3f9a")
        XCTAssertEqual(rig.api.requests.first?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-api03-abcdefghijklmnop3f9a")
    }

    func testTheFirstKeyChoosesTheProviderAndTheRecommendedModel() async {
        let rig = makeRig([.json(200, AIFixtures.anthropicDefault)])
        await rig.store.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic)
        XCTAssertEqual(rig.settings.ai.provider, .anthropic)
        XCTAssertEqual(rig.settings.ai.anthropicModel, "claude-opus-5-5")
        XCTAssertEqual(rig.store.selectedModel(for: .anthropic)?.displayName, "Claude Opus 5.5")
    }

    func testASecondKeyDoesNotTakeOverAsTheDefault() async {
        let rig = makeRig([.json(200, AIFixtures.anthropicDefault), .json(200, AIFixtures.openAIDefault)])
        await rig.store.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic)
        await rig.store.saveKey("sk-openai-key-0123456789abcd", for: .openAI)
        XCTAssertEqual(rig.settings.ai.provider, .anthropic)
        XCTAssertEqual(rig.settings.ai.openAIModel, "gpt-6-astra")
        rig.store.setDefaultProvider(.openAI)
        XCTAssertEqual(rig.settings.ai.provider, .openAI)
    }

    func testOnlyUsableModelsAreOfferedAndCanBeChosen() async {
        let rig = makeRig([.json(200, AIFixtures.anthropicDefault)])
        await rig.store.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic)
        XCTAssertEqual(rig.store.visibleModels(for: .anthropic).map(\.id), ["claude-opus-5-5", "claude-sonnet-5-5", "claude-text-1"])
        rig.store.selectModel("claude-text-1", for: .anthropic)
        XCTAssertEqual(rig.store.selectedModel(for: .anthropic)?.isTextAndPDFOnly, true)
    }

    func testABlankKeyIsIgnored() async {
        let rig = makeRig()
        await rig.store.saveKey("   \n", for: .openAI)
        XCTAssertFalse(rig.store.hasKey(.openAI))
        XCTAssertTrue(rig.api.requests.isEmpty)
    }

    // MARK: Problems

    func testARejectedKeyShowsWhyAndCanBeRemoved() async {
        let rig = makeRig([.json(401, "{}")])
        await rig.store.saveKey("sk-ant-wrong-key-0123456789", for: .anthropic)
        XCTAssertEqual(rig.store.status(for: .anthropic), .failed(.rejected))
        guard case .failed(let error) = rig.store.status(for: .anthropic) else { return XCTFail("failed") }
        XCTAssertEqual(error.message, "This key was rejected")
        XCTAssertTrue(rig.store.hasKey(.anthropic), "still there to be removed or replaced")
        XCTAssertNil(rig.settings.ai.provider, "a key that doesn't work isn't made the default")
        rig.store.removeKey(for: .anthropic)
        XCTAssertEqual(rig.store.status(for: .anthropic), .noKey)
    }

    func testBeingOfflineSaysSoAndKeepsWhatWasKnown() async {
        let rig = makeRig([.json(200, AIFixtures.anthropicDefault), .failure(URLError(.notConnectedToInternet))])
        await rig.store.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic)
        await rig.store.refreshModels(for: .anthropic)
        XCTAssertEqual(rig.store.status(for: .anthropic), .failed(.network))
        XCTAssertEqual(AIError.network.message, "No network connection")
        XCTAssertEqual(rig.store.visibleModels(for: .anthropic).count, 3, "the picker still works")
        XCTAssertEqual(rig.settings.ai.anthropicModel, "claude-opus-5-5")
    }

    func testAKeychainThatWontSaveIsReported() async {
        let settings = SettingsStore(storage: SettingsStorage(directory: directory), onSaved: {})
        let store = AIAccountStore(secrets: FailingSecretStore(), client: AIModelClient(transport: FakeAPI().transport), cacheStorage: AIModelCacheStorage(directory: directory), settings: settings)
        await store.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic)
        XCTAssertNotNil(store.storageProblem)
        XCTAssertFalse(store.hasKey(.anthropic))
    }

    // MARK: Models changing

    func testASavedModelThatDisappearsIsReplacedAndSaidOnce() async {
        let rig = makeRig([.json(200, AIFixtures.anthropicDefault)])
        rig.settings.ai.anthropicModel = "claude-retired-9"
        await rig.store.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic)
        XCTAssertEqual(rig.settings.ai.anthropicModel, "claude-opus-5-5", "back to the default")
        let notice = rig.store.notices[.anthropic] ?? ""
        XCTAssertTrue(notice.contains("claude-retired-9"), notice)
        XCTAssertTrue(notice.contains("Claude Opus 5.5"), notice)
        rig.store.dismissNotice(for: .anthropic)
        XCTAssertNil(rig.store.notices[.anthropic])
    }

    func testNoNoticeTheFirstTimeAModelIsPicked() async {
        let rig = makeRig([.json(200, AIFixtures.anthropicDefault)])
        await rig.store.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic)
        XCTAssertNil(rig.store.notices[.anthropic])
    }

    func testWithoutTheRecommendedModelTheFirstListedOneIsUsed() async {
        let page = AIFixtures.anthropicPage([("claude-other-1", "Claude Other", true, true), ("claude-other-2", "Claude Other 2", true, true)])
        let rig = makeRig([.json(200, page)])
        await rig.store.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic)
        XCTAssertEqual(rig.settings.ai.anthropicModel, "claude-other-1")
    }

    func testAChosenModelThatStillExistsIsKept() async {
        let rig = makeRig([.json(200, AIFixtures.anthropicDefault)])
        rig.settings.ai.anthropicModel = "claude-sonnet-5-5"
        await rig.store.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic)
        XCTAssertEqual(rig.settings.ai.anthropicModel, "claude-sonnet-5-5")
        XCTAssertNil(rig.store.notices[.anthropic])
    }

    func testShowingAllOpenAIModelsChangesTheListNotWhatIsAvailable() async {
        let rig = makeRig([.json(200, AIFixtures.openAIDefault)])
        await rig.store.saveKey("sk-openai-key-0123456789abcd", for: .openAI)
        XCTAssertEqual(rig.store.visibleModels(for: .openAI).count, 3)
        rig.settings.ai.showsAllOpenAIModels = true
        XCTAssertEqual(rig.store.visibleModels(for: .openAI).count, 8)
        rig.store.selectModel("whisper-2", for: .openAI)
        XCTAssertEqual(rig.store.selectedModel(for: .openAI)?.id, "whisper-2")
        rig.settings.ai.showsAllOpenAIModels = false
        XCTAssertEqual(rig.store.selectedModel(for: .openAI)?.id, "whisper-2", "still the chosen one")
    }

    // MARK: Removing

    func testRemovingTheKeyClearsEverythingAndMovesTheDefault() async {
        let rig = makeRig([.json(200, AIFixtures.anthropicDefault), .json(200, AIFixtures.openAIDefault)])
        await rig.store.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic)
        await rig.store.saveKey("sk-openai-key-0123456789abcd", for: .openAI)
        rig.store.removeKey(for: .anthropic)
        XCTAssertNil(rig.secrets.secret(for: .anthropic))
        XCTAssertNil(rig.store.maskedKey(for: .anthropic))
        XCTAssertTrue(rig.store.visibleModels(for: .anthropic).isEmpty)
        XCTAssertNil(rig.settings.ai.anthropicModel)
        XCTAssertEqual(rig.settings.ai.provider, .openAI, "the one that still has a key")
        rig.store.removeKey(for: .openAI)
        XCTAssertNil(rig.settings.ai.provider)
        XCTAssertNil(AIModelCacheStorage(directory: directory).load().entry(for: .anthropic), "the cached list is gone too")
    }

    func testAnAnswerThatArrivesAfterTheKeyWasRemovedIsIgnored() async throws {
        let rig = makeRig([.json(200, AIFixtures.anthropicDefault)])
        try rig.secrets.setSecret("sk-ant-key-0123456789abcdef", for: .anthropic)
        let store = rig.store
        rig.api.setDelay(.milliseconds(80))
        let slow = Task { await store.refreshModels(for: .anthropic) }
        try await Task.sleep(for: .milliseconds(20))
        store.removeKey(for: .anthropic)
        await slow.value
        XCTAssertEqual(store.status(for: .anthropic), .noKey)
        XCTAssertTrue(store.visibleModels(for: .anthropic).isEmpty, "not brought back by a late answer")
    }

    func testAKeyCanOnlyBeChosenAsTheDefaultOnceItIsThere() {
        let rig = makeRig()
        rig.store.setDefaultProvider(.openAI)
        XCTAssertNil(rig.settings.ai.provider)
    }

    // MARK: Staying up to date

    func testTheListIsKeptBetweenLaunchesSoItWorksOffline() async {
        let rig = makeRig([.json(200, AIFixtures.anthropicDefault)])
        await rig.store.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic)
        let relaunched = makeRig(secrets: rig.secrets)
        XCTAssertEqual(relaunched.store.status(for: .anthropic), .works)
        XCTAssertEqual(relaunched.store.visibleModels(for: .anthropic).count, 3)
        XCTAssertEqual(relaunched.store.maskedKey(for: .anthropic), "sk-ant-•••cdef")
        XCTAssertTrue(relaunched.api.requests.isEmpty, "no network needed")
    }

    func testAKeyWithNoListYetShowsAsSaved() throws {
        let secrets = InMemorySecretStore()
        try secrets.setSecret("sk-ant-key-0123456789abcdef", for: .anthropic)
        XCTAssertEqual(makeRig(secrets: secrets).store.status(for: .anthropic), .saved)
    }

    func testOpeningSettingsAsksAgainOnlyOnceTheListIsADayOld() async {
        let rig = makeRig([.json(200, AIFixtures.anthropicDefault), .json(200, AIFixtures.anthropicDefault)])
        await rig.store.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic)
        XCTAssertEqual(rig.api.requests.count, 1)
        now = now.addingTimeInterval(AIAccountStore.staleAfter - 60)
        await rig.store.refreshStaleModels()
        XCTAssertEqual(rig.api.requests.count, 1, "not yet a day old")
        now = now.addingTimeInterval(120)
        await rig.store.refreshStaleModels()
        XCTAssertEqual(rig.api.requests.count, 2, "now it is")
    }

    func testOpeningSettingsWithNoKeysAsksNothing() async {
        let rig = makeRig()
        await rig.store.refreshStaleModels()
        XCTAssertTrue(rig.api.requests.isEmpty)
    }

    func testAKeyIsNeverFoundInAPublishedValue() async {
        let rig = makeRig([.json(200, AIFixtures.anthropicDefault)])
        await rig.store.saveKey("sk-ant-supersecret-0123456789abcdef", for: .anthropic)
        let description = "\(rig.store.status) \(rig.store.models) \(rig.store.notices) \(rig.store.maskedKey(for: .anthropic) ?? "")"
        XCTAssertFalse(description.contains("supersecret"))
        XCTAssertFalse(AIAccountStore.mask("sk-ant-supersecret-0123456789abcdef").contains("secret"))
    }

    func testTheMask() {
        XCTAssertEqual(AIAccountStore.mask("sk-ant-api03-xxxxxxxxxxxx3f9a"), "sk-ant-•••3f9a")
        XCTAssertEqual(AIAccountStore.mask("sk-proj-abcdefghijklmnop1234"), "sk-•••1234")
        XCTAssertEqual(AIAccountStore.mask("abcdefghijklmnop1234"), "•••1234")
        XCTAssertEqual(AIAccountStore.mask("short"), "•••", "too short to show any of it")
    }
}

// MARK: - The network permission

final class NetworkEntitlementTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    /// The part of project.yml that describes one target.
    private func section(of target: String, in yml: String) -> String? {
        guard let start = yml.range(of: "\n  \(target):\n") else { return nil }
        let rest = yml[start.upperBound...]
        let end = rest.range(of: "\n  [A-Za-z]+:\n")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    func testOnlyTheAppMayMakeOutgoingConnectionsNotTheWidget() throws {
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let app = try XCTUnwrap(section(of: "FishBrain", in: yml))
        let widget = try XCTUnwrap(section(of: "FishBrainWidget", in: yml))
        XCTAssertTrue(app.contains("com.apple.security.network.client: true"), "the sandboxed app needs this to reach Anthropic and OpenAI")
        XCTAssertFalse(widget.contains("network"), "the widget never goes online")
    }

    func testTheGeneratedEntitlementsFileHasIt() throws {
        let file = root.appendingPathComponent("FishBrain/FishBrain.entitlements")
        guard let data = try? Data(contentsOf: file) else { throw XCTSkip("run xcodegen first") }
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["com.apple.security.network.client"] as? Bool, true)
        let widgetFile = root.appendingPathComponent("FishBrainWidget/FishBrainWidget.entitlements")
        if let widgetData = try? Data(contentsOf: widgetFile),
           let widgetPlist = try? PropertyListSerialization.propertyList(from: widgetData, format: nil) as? [String: Any] {
            XCTAssertNil(widgetPlist["com.apple.security.network.client"])
        }
    }
}

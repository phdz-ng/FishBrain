import Foundation
import OSLog

/// The models a key could use, kept between launches so the picker still works offline.
struct AIModelCache: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var models: [AIModel]
        var fetchedAt: Date
    }

    var entries: [String: Entry] = [:]

    func entry(for provider: AIProvider) -> Entry? { entries[provider.rawValue] }
    mutating func set(_ entry: Entry?, for provider: AIProvider) { entries[provider.rawValue] = entry }
}

/// `ai-models.json` in the app's shared folder. Only model names and what they can do: nothing secret.
struct AIModelCacheStorage: Sendable {
    static let fileName = "ai-models.json"

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) {
        self.directory = directory
    }

    static func shared() -> AIModelCacheStorage {
        AIModelCacheStorage(directory: AppGroup.storageDirectory())
    }

    func load() -> AIModelCache {
        guard let data = try? Data(contentsOf: fileURL) else { return AIModelCache() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(AIModelCache.self, from: data)) ?? AIModelCache()
    }

    func save(_ cache: AIModelCache) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(cache).write(to: fileURL, options: .atomic)
    }
}

/// Everything about the two AI accounts: whether there is a key, whether it works, which models it can
/// use, and which one is chosen. Keys are kept in the Keychain and read only when needed; this class
/// never holds one in a published property.
@MainActor
final class AIAccountStore: ObservableObject {
    enum KeyStatus: Equatable {
        case noKey
        /// A key is saved but hasn't been checked in this session and there is no model list yet.
        case saved
        case checking
        case works
        case failed(AIError)
    }

    /// The model list is refreshed when Settings opens if it is older than this.
    static let staleAfter: TimeInterval = 24 * 3600

    @Published private(set) var status: [AIProvider: KeyStatus] = [:]
    /// What each provider's list returned (before filtering for the picker).
    @Published private(set) var models: [AIProvider: [AIModel]] = [:]
    /// Said once when a saved model is no longer available and another took its place.
    @Published private(set) var notices: [AIProvider: String] = [:]
    /// The Keychain wouldn't save or remove a key.
    @Published private(set) var storageProblem: String?
    /// Whether the model that comes with the Mac can be used, and what it can do. It has no key and no list.
    @Published private(set) var onDevice: OnDeviceStatus

    private let onDeviceModel: OnDeviceModelProviding
    private let secrets: SecretStore
    private let client: AIModelClient
    private let cacheStorage: AIModelCacheStorage
    private let settings: SettingsStore
    private let clock: () -> Date
    private var cache: AIModelCache
    private var maskedKeys: [AIProvider: String] = [:]
    private var generation: [AIProvider: Int] = [:]
    private let logger = Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "ai")

    init(
        secrets: SecretStore,
        client: AIModelClient = AIModelClient(),
        cacheStorage: AIModelCacheStorage,
        settings: SettingsStore,
        onDeviceModel: OnDeviceModelProviding = SystemOnDeviceModel(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.onDeviceModel = onDeviceModel
        onDevice = onDeviceModel.status()
        self.secrets = secrets
        self.client = client
        self.cacheStorage = cacheStorage
        self.settings = settings
        self.clock = clock
        self.cache = cacheStorage.load()
        for provider in AIProvider.cloud {
            if let key = secrets.secret(for: provider) {
                maskedKeys[provider] = Self.mask(key)
                let entry = cache.entry(for: provider)
                models[provider] = entry?.models ?? []
                status[provider] = entry == nil ? .saved : .works
            } else {
                status[provider] = .noKey
            }
        }
    }

    // MARK: Reading

    func hasKey(_ provider: AIProvider) -> Bool { maskedKeys[provider] != nil }

    /// Whether cards can be made with this provider now: a key for a company, or a model ready on the Mac.
    func isUsable(_ provider: AIProvider) -> Bool {
        provider.isOnDevice ? onDevice.isAvailable : hasKey(provider)
    }

    /// Asks the system again whether Apple Intelligence is ready (it may have been turned on, or finished downloading).
    func refreshOnDevice() {
        let status = onDeviceModel.status()
        if status != onDevice { onDevice = status }
    }

    /// "sk-ant-•••3f9a": enough to tell keys apart, not enough to use.
    func maskedKey(for provider: AIProvider) -> String? { maskedKeys[provider] }

    /// The key itself, for a request. Read from the Keychain each time.
    func apiKey(for provider: AIProvider) -> String? { provider.needsKey ? secrets.secret(for: provider) : nil }

    func status(for provider: AIProvider) -> KeyStatus { status[provider] ?? .noKey }

    /// What the picker lists.
    func visibleModels(for provider: AIProvider) -> [AIModel] {
        if provider.isOnDevice { return onDevice.isAvailable ? [.onDevice(onDevice)] : [] }
        return ModelFilter.visible(models[provider] ?? [], for: provider, showAllOpenAI: settings.ai.showsAllOpenAIModels)
    }

    /// The chosen model, if the key can use it.
    func selectedModel(for provider: AIProvider) -> AIModel? {
        if provider.isOnDevice { return onDevice.isAvailable ? .onDevice(onDevice) : nil }
        guard let id = settings.ai.model(for: provider) else { return nil }
        return (models[provider] ?? []).first { $0.id == id }
    }

    static func mask(_ key: String) -> String {
        let prefix = key.hasPrefix("sk-ant-") ? "sk-ant-" : (key.hasPrefix("sk-") ? "sk-" : "")
        guard key.count >= prefix.count + 8 else { return "•••" }
        return "\(prefix)•••\(key.suffix(4))"
    }

    // MARK: Keys

    /// Saves a key in the Keychain and checks it by asking for the model list.
    func saveKey(_ raw: String, for provider: AIProvider) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try secrets.setSecret(key, for: provider)
            storageProblem = nil
        } catch {
            storageProblem = "The Keychain wouldn't save the key. Check that your Keychain is unlocked and try again."
            logger.error("Keychain save failed for \(provider.rawValue, privacy: .public)")
            return
        }
        maskedKeys[provider] = Self.mask(key)
        notices[provider] = nil
        await refreshModels(for: provider)
    }

    func removeKey(for provider: AIProvider) {
        do {
            try secrets.removeSecret(for: provider)
            storageProblem = nil
        } catch {
            storageProblem = "The Keychain wouldn't remove the key."
            logger.error("Keychain remove failed for \(provider.rawValue, privacy: .public)")
            return
        }
        generation[provider, default: 0] += 1 // an answer still on its way is no longer wanted
        maskedKeys[provider] = nil
        models[provider] = nil
        notices[provider] = nil
        status[provider] = .noKey
        cache.set(nil, for: provider)
        saveCache()
        var ai = settings.ai
        ai.setModel(nil, for: provider)
        if ai.provider == provider { ai.provider = AIProvider.cloud.first { $0 != provider && hasKey($0) } }
        settings.ai = ai
    }

    // MARK: Models

    /// Asks the provider which models the key can use. On success the list is kept (and cached); on
    /// failure the old list stays, so the picker still works.
    func refreshModels(for provider: AIProvider) async {
        guard let key = secrets.secret(for: provider) else { return }
        generation[provider, default: 0] += 1
        let mine = generation[provider]!
        status[provider] = .checking
        do {
            let fetched = try await client.models(for: provider, apiKey: key)
            guard generation[provider] == mine else { return }
            models[provider] = fetched
            cache.set(AIModelCache.Entry(models: fetched, fetchedAt: clock()), for: provider)
            saveCache()
            status[provider] = .works
            applyModelDefaults(for: provider)
        } catch is CancellationError {
            if generation[provider] == mine { status[provider] = models[provider]?.isEmpty == false ? .works : .saved }
        } catch {
            guard generation[provider] == mine else { return }
            status[provider] = .failed((error as? AIError) ?? .badResponse)
        }
    }

    /// When Settings opens: lists older than a day are asked for again.
    func refreshStaleModels() async {
        refreshOnDevice()
        for provider in AIProvider.cloud where hasKey(provider) {
            let age = cache.entry(for: provider).map { clock().timeIntervalSince($0.fetchedAt) }
            if age == nil || age! > Self.staleAfter { await refreshModels(for: provider) }
        }
    }

    /// Picks a model when there is none, or its saved one is gone, and makes the first provider with a key
    /// the default one.
    private func applyModelDefaults(for provider: AIProvider) {
        var ai = settings.ai
        let usable = provider == .anthropic ? ModelFilter.anthropicUsable(models[provider] ?? []) : (models[provider] ?? [])
        if !usable.isEmpty {
            let saved = ai.model(for: provider)
            if saved == nil || !usable.contains(where: { $0.id == saved }) {
                let visible = visibleModels(for: provider)
                let replacement = usable.first { $0.id == provider.recommendedModelID } ?? visible.first ?? usable[0]
                ai.setModel(replacement.id, for: provider)
                if let saved {
                    notices[provider] = "“\(saved)” isn't available for this key any more, so FishBrain switched to \(replacement.displayName)."
                }
            }
        }
        if ai.provider == nil { ai.provider = provider }
        settings.ai = ai
    }

    func dismissNotice(for provider: AIProvider) {
        notices[provider] = nil
    }

    // MARK: Choosing

    func selectModel(_ id: String, for provider: AIProvider) {
        var ai = settings.ai
        ai.setModel(id, for: provider)
        settings.ai = ai
        notices[provider] = nil
    }

    func setDefaultProvider(_ provider: AIProvider) {
        guard isUsable(provider) else { return }
        var ai = settings.ai
        ai.provider = provider
        settings.ai = ai
    }

    private func saveCache() {
        do { try cacheStorage.save(cache) } catch {
            logger.error("Could not save the model list: \(error.localizedDescription)")
        }
    }
}

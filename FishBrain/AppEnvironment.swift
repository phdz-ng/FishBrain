import Foundation

/// The app's stores, created once and shared by the main window and the notch so both always show
/// the same library, playback state and accent.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let deckStore: DeckStore
    let playbackStore: PlaybackStore
    let settingsStore: SettingsStore
    let studyStore: StudyStore
    /// The last Review sprints, for the setup sheet's estimate and the results' chips.
    let runHistoryStore: RunHistoryStore
    let sessionStore: SessionStore
    /// Who runs the study clock: the notch's session or a Review sprint, never both.
    let studyClockGate: StudyClockGate
    /// The AI accounts: keys (in the Keychain), models and the choices made in Settings > AI.
    let aiStore: AIAccountStore
    /// The Create with AI form, kept so it is as it was left after a visit to a deck.
    let composer: ComposerModel
    /// The offer to make a card from a copy, shown by every display's notch.
    let copyOfferStore = CopyOfferStore()

    private init() {
        // Earlier builds kept the library where the widget could not see it.
        StorageMigration.migrateIfNeeded()

        #if DEBUG
        // `-FishBrainSampleData` shows sample decks without touching the real library.
        if ProcessInfo.processInfo.arguments.contains("-FishBrainSampleData") {
            // Everything throwaway, so sample mode never writes the real library, playback or settings.
            deckStore = PreviewData.store()
            playbackStore = PreviewData.playback()
            settingsStore = PreviewData.settings()
            // `-FishBrainSkipWelcome` starts without the welcome sheet, for screenshots.
            if ProcessInfo.processInfo.arguments.contains("-FishBrainSkipWelcome") { settingsStore.hasSeenWelcome = true }
            // `-FishBrainAppearance dark` (or light, system) and `-FishBrainAccent teal`, for screenshots.
            if let raw = UserDefaults.standard.string(forKey: "FishBrainAppearance"), let choice = AppearanceChoice(rawValue: raw) {
                settingsStore.appearance = choice
            }
            if let raw = UserDefaults.standard.string(forKey: "FishBrainAccent"), let choice = AccentChoice(rawValue: raw) {
                settingsStore.accent = choice
            }
            let sampleDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainSample-\(UUID().uuidString)")
            studyStore = StudyStore(storage: StudyStorage(directory: sampleDirectory))
            runHistoryStore = RunHistoryStore(storage: RunHistoryStorage(directory: sampleDirectory))
            sessionStore = SessionStore(storage: SessionStorage(directory: sampleDirectory), studyStorage: StudyStorage(directory: sampleDirectory))
            studyClockGate = StudyClockGate(sessions: sessionStore)
            // Sample mode must never touch the real Keychain.
            let secrets = InMemorySecretStore()
            var estimator: CostEstimating = ComposerModel.estimateWithProvider
            var generators: GeneratorFactory = ComposerModel.realGenerator
            if ProcessInfo.processInfo.arguments.contains("-FishBrainSampleAI") {
                // The model on the Mac is the real one (it stays on the Mac); the companies' are pretend.
                generators = { provider, key in provider.provider.isOnDevice ? ComposerModel.realGenerator(provider, key) : SampleGenerator() }
                // `-FishBrainSampleAI` adds a pretend Anthropic key and model, and a made-up cost, so Create with
                // AI can be seen ready to go. Nothing is sent anywhere.
                Self.seedSampleAI(secrets: secrets, directory: sampleDirectory, settings: settingsStore)
                // `-FishBrainSampleOnDevice`: Apple Intelligence is the one chosen (if this Mac has it).
                if ProcessInfo.processInfo.arguments.contains("-FishBrainSampleOnDevice") { settingsStore.ai.provider = .appleIntelligence }
                estimator = { request, model, _ in
                    AIPricing.price(for: model.id).map { CostEstimate(inputTokens: 52_000, cardCount: request.cardCount, price: $0) }
                }
            }
            aiStore = AIAccountStore(secrets: secrets, cacheStorage: AIModelCacheStorage(directory: sampleDirectory), settings: settingsStore)
            composer = ComposerModel(settings: settingsStore, ai: aiStore, costEstimator: estimator, generatorFactory: generators)
            if ProcessInfo.processInfo.arguments.contains("-FishBrainSampleSources") {
                let composer = composer
                Task { await composer.addSampleSources() }
            }
            if ProcessInfo.processInfo.arguments.contains("-FishBrainSampleDraft") || ProcessInfo.processInfo.arguments.contains("-FishBrainSampleDraftInDeck") {
                // A run at launch with the pretend provider, to look at the generating and review screens.
                let composer = composer, decks = deckStore.decks
                composer.focus = "Focus on the steps of glycolysis and the Krebs cycle, and the ATP counts."
                composer.choosePreset(20)
                // `-FishBrainSampleDraftInDeck`: for the first deck, as "Generate…" on a deck does.
                if ProcessInfo.processInfo.arguments.contains("-FishBrainSampleDraftInDeck"), let first = decks.first {
                    composer.prepareForDeck(first.id)
                }
                composer.startRun(decks: decks)
            }
            FirstLaunch.run(decks: deckStore, settings: settingsStore)
            return
        }
        #endif
        deckStore = DeckStore()
        playbackStore = PlaybackStore()
        settingsStore = SettingsStore()
        studyStore = StudyStore()
        runHistoryStore = RunHistoryStore()
        sessionStore = SessionStore()
        studyClockGate = StudyClockGate(sessions: sessionStore)
        aiStore = AIAccountStore(secrets: KeychainSecretStore(), cacheStorage: .shared(), settings: settingsStore)
        composer = ComposerModel(settings: settingsStore, ai: aiStore)
        // First launch: the "Getting Started" deck, before the window or the notch show anything.
        FirstLaunch.run(decks: deckStore, settings: settingsStore)
    }

    #if DEBUG
    private static func seedSampleAI(secrets: InMemorySecretStore, directory: URL, settings: SettingsStore) {
        try? secrets.setSecret("sk-ant-sample-key-0000000000", for: .anthropic)
        let opus = AIModel(
            provider: .anthropic, id: "claude-opus-5-5", displayName: "Claude Opus 5.5", created: nil, supportsImages: true,
            supportsStructuredOutput: true, supportsEffort: true, maxInputTokens: 1_000_000, maxOutputTokens: 128_000
        )
        var cache = AIModelCache()
        cache.set(AIModelCache.Entry(models: [opus], fetchedAt: Date()), for: .anthropic)
        try? AIModelCacheStorage(directory: directory).save(cache)
        settings.ai = AISettings(provider: .anthropic, anthropicModel: opus.id)
    }
    #endif
}

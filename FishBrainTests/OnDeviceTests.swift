import AppKit
import CoreText
import XCTest

/// Apple Intelligence, the on-device provider (FLAS-52): what the Mac can do, cutting the material to fit the model's
/// small context, the generator with a pretend model, and how the app treats a provider with no key. The real model is
/// only used by `OnDeviceLiveTests`.

// MARK: - Fixtures

enum OnDeviceFixtures {
    /// A PDF with real text on each page (the usual fixture's pages are blank).
    static func pdf(pages: [String], firstPage: Int = 1) throws -> PDFSource {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: CGRect(x: 40, y: 40, width: 530, height: 700), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
            context.endPDFPage()
        }
        context.closePDF()
        var pdf = try GenerationInputs.pdf(from: data as Data, filename: "cells.pdf")
        pdf.firstPage = firstPage
        return pdf
    }

    static func partial(_ name: String?, _ cards: [(String?, String?, Int?)]) -> OnDevicePartialDeck {
        OnDevicePartialDeck(deckName: name, cards: cards.map { OnDevicePartialCard(front: $0.0, back: $0.1, sourcePage: $0.2) })
    }

    /// A paragraph of this many characters.
    static func paragraph(_ count: Int, _ seed: String = "word ") -> String {
        String(String(repeating: seed, count: count / seed.count + 1).prefix(count))
    }

    static func request(
        _ sources: [GenerationSource], count: Int = 4, focus: String = "", task: GenerationTask = .create, existing: [String] = []
    ) -> GenerationRequest {
        GenerationRequest(sources: sources, focus: focus, cardCount: count, existingFronts: existing, task: task, modelID: AIProvider.onDeviceModelID)
    }

    static func text(_ text: String) -> GenerationSource { .text(TextSource(text: text, name: nil)) }
}

/// Says what it is told to, one script per call, and remembers what it was asked.
final class FakeOnDeviceEngine: OnDeviceEngine, @unchecked Sendable {
    enum Step {
        case deck(OnDevicePartialDeck)
        case fail(OnDeviceFailure)
        case hang
    }

    private let lock = NSLock()
    private var scripts: [[Step]]
    private var _requests: [OnDeviceRequest] = []
    private var _terminated = false

    init(_ scripts: [[Step]]) { self.scripts = scripts }

    var requests: [OnDeviceRequest] { lock.withLock { _requests } }
    var terminated: Bool { lock.withLock { _terminated } }

    func stream(_ request: OnDeviceRequest) -> AsyncThrowingStream<OnDevicePartialDeck, Error> {
        let script: [Step] = lock.withLock {
            _requests.append(request)
            return scripts.isEmpty ? [.fail(.other)] : scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for step in script {
                    if Task.isCancelled { break }
                    switch step {
                    case .deck(let deck): continuation.yield(deck)
                    case .fail(let failure):
                        continuation.finish(throwing: failure)
                        return
                    case .hang:
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { [self] _ in
                lock.withLock { _terminated = true }
                task.cancel()
            }
        }
    }
}

/// An answer that can change, for "turned Apple Intelligence on".
final class MutableOnDeviceModel: OnDeviceModelProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: OnDeviceStatus
    init(_ value: OnDeviceStatus) { self.value = value }
    func set(_ new: OnDeviceStatus) { lock.withLock { value = new } }
    func status() -> OnDeviceStatus { lock.withLock { value } }
}

// MARK: - What the Mac can do

final class OnDeviceStatusTests: XCTestCase {
    func testAvailableMeansNoReason() {
        let status = OnDeviceStatus.available(contextSize: 8192, supportsImages: true)
        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.headline, "Available")
        XCTAssertNil(status.detail)
        XCTAssertEqual(status.contextSize, 8192)
    }

    func testEachReasonSaysWhatToDo() {
        let cases: [(OnDeviceStatus.Reason, String)] = [
            (.needsNewerSystem, "Needs macOS 26 or later."),
            (.deviceNotEligible, "This Mac can't run Apple Intelligence."),
            (.appleIntelligenceOff, "Turn on Apple Intelligence in System Settings."),
            (.modelNotReady, "Apple Intelligence is still getting ready. Try again in a little while."),
            (.unknown, "Apple Intelligence isn't ready on this Mac."),
        ]
        for (reason, detail) in cases {
            let status = OnDeviceStatus.unavailable(reason)
            XCTAssertFalse(status.isAvailable)
            XCTAssertEqual(status.headline, "Not available on this Mac")
            XCTAssertEqual(status.detail, detail)
        }
    }

    func testTheRealQuestionIsAnsweredWithoutCrashing() {
        let status = SystemOnDeviceModel().status()
        XCTAssertGreaterThan(status.contextSize, 0)
        if status.isAvailable { XCTAssertNil(status.reason) } else { XCTAssertNotNil(status.detail) }
    }
}

// MARK: - A provider with no key

final class OnDeviceProviderTests: XCTestCase {
    func testItIsAThirdProviderThatNeedsNoKey() {
        XCTAssertEqual(AIProvider.cloud, [.anthropic, .openAI])
        XCTAssertTrue(AIProvider.allCases.contains(.appleIntelligence))
        XCTAssertTrue(AIProvider.appleIntelligence.isOnDevice)
        XCTAssertFalse(AIProvider.appleIntelligence.needsKey)
        XCTAssertTrue(AIProvider.anthropic.needsKey)
        XCTAssertEqual(AIProvider.appleIntelligence.displayName, "Apple Intelligence")
        XCTAssertEqual(AIProvider.appleIntelligence.recommendedModelID, AIProvider.onDeviceModelID)
    }

    func testItsOneModelHasNoPrice() {
        XCTAssertNil(AIPricing.price(for: AIProvider.onDeviceModelID), "so no cost is shown")
        let model = AIModel.onDevice(.available(contextSize: 8192, supportsImages: true))
        XCTAssertEqual(model.provider, .appleIntelligence)
        XCTAssertEqual(model.maxInputTokens, 8192)
        XCTAssertEqual(model.supportsImages, true)
        XCTAssertEqual(AIModel.onDevice(.available()).supportsImages, false)
    }

    func testTheChoiceIsSavedLikeAnyOther() throws {
        var settings = AISettings(provider: .appleIntelligence)
        XCTAssertEqual(settings.model(for: .appleIntelligence), AIProvider.onDeviceModelID)
        settings.setModel("something", for: .appleIntelligence)
        XCTAssertEqual(settings.model(for: .appleIntelligence), AIProvider.onDeviceModelID, "it has only one")
        let decoded = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.provider, .appleIntelligence)
        let old = try JSONDecoder().decode(AISettings.self, from: Data(#"{"provider":"openAI"}"#.utf8))
        XCTAssertEqual(old.provider, .openAI, "files from before are read as they were")
    }
}

@MainActor
final class OnDeviceAccountTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try PictureFixtures.tempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// Each store gets a folder of its own, so one's saved choices aren't read by the next.
    private func store(_ onDevice: OnDeviceModelProviding, secrets: InMemorySecretStore = InMemorySecretStore()) -> (AIAccountStore, SettingsStore) {
        let folder = directory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsStore(storage: SettingsStorage(directory: folder), onSaved: {})
        let store = AIAccountStore(
            secrets: secrets, client: AIModelClient(transport: FakeAPI().transport), cacheStorage: AIModelCacheStorage(directory: folder),
            settings: settings, onDeviceModel: onDevice
        )
        return (store, settings)
    }

    func testUsableMeansAKeyForACompanyAndAModelReadyOnTheMac() {
        let (ready, _) = store(FixedOnDeviceModel(value: .available()))
        XCTAssertTrue(ready.isUsable(.appleIntelligence))
        XCTAssertFalse(ready.isUsable(.anthropic), "no key")
        XCTAssertFalse(ready.hasKey(.appleIntelligence), "it has no key to have")
        let (off, _) = store(FixedOnDeviceModel(value: .unavailable(.appleIntelligenceOff)))
        XCTAssertFalse(off.isUsable(.appleIntelligence))
    }

    func testItCanBeTheDefaultOnlyWhenItIsReady() {
        let (ready, settings) = store(FixedOnDeviceModel(value: .available()))
        ready.setDefaultProvider(.appleIntelligence)
        XCTAssertEqual(settings.ai.provider, .appleIntelligence)

        let (off, offSettings) = store(FixedOnDeviceModel(value: .unavailable(.deviceNotEligible)))
        off.setDefaultProvider(.appleIntelligence)
        XCTAssertNil(offSettings.ai.provider)
    }

    func testItsOneModelIsOfferedWhenReady() {
        let (ready, _) = store(FixedOnDeviceModel(value: .available(contextSize: 4096)))
        XCTAssertEqual(ready.visibleModels(for: .appleIntelligence).map(\.id), [AIProvider.onDeviceModelID])
        XCTAssertEqual(ready.selectedModel(for: .appleIntelligence)?.maxInputTokens, 4096)
        let (off, _) = store(FixedOnDeviceModel(value: .unavailable(.modelNotReady)))
        XCTAssertTrue(off.visibleModels(for: .appleIntelligence).isEmpty)
        XCTAssertNil(off.selectedModel(for: .appleIntelligence))
    }

    func testTurningAppleIntelligenceOnIsNoticedOnRefresh() {
        let mutable = MutableOnDeviceModel(.unavailable(.appleIntelligenceOff))
        let (account, _) = store(mutable)
        XCTAssertFalse(account.onDevice.isAvailable)
        mutable.set(.available(contextSize: 8192))
        XCTAssertFalse(account.onDevice.isAvailable, "not until asked again")
        account.refreshOnDevice()
        XCTAssertTrue(account.onDevice.isAvailable)
        XCTAssertEqual(account.onDevice.contextSize, 8192)
    }

    func testThereIsNoKeyToReadForIt() {
        let secrets = InMemorySecretStore()
        let (account, _) = store(FixedOnDeviceModel(value: .available()), secrets: secrets)
        XCTAssertNil(account.apiKey(for: .appleIntelligence))
        XCTAssertNil(account.maskedKey(for: .appleIntelligence))
    }

    func testRemovingAKeyDoesNotSwitchToTheOnDeviceModelBehindAnyonesBack() async {
        let api = FakeAPI([.json(200, AIFixtures.anthropicDefault)])
        let settings = SettingsStore(storage: SettingsStorage(directory: directory), onSaved: {})
        let account = AIAccountStore(
            secrets: InMemorySecretStore(), client: AIModelClient(transport: api.transport), cacheStorage: AIModelCacheStorage(directory: directory),
            settings: settings, onDeviceModel: FixedOnDeviceModel(value: .available())
        )
        await account.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic)
        XCTAssertEqual(settings.ai.provider, .anthropic)
        account.removeKey(for: .anthropic)
        XCTAssertNil(settings.ai.provider, "the person chooses it")
    }
}

// MARK: - Cutting the material

final class OnDeviceChunkerTests: XCTestCase {
    func testHowMuchFitsFollowsTheContextSize() {
        // (context - 750 fixed - 12 cards x 90) x 0.9 x 3 characters a token
        XCTAssertEqual(OnDeviceChunker.materialCharacters(contextSize: 8192), 17_177)
        XCTAssertEqual(OnDeviceChunker.materialCharacters(contextSize: 4096), 6_118)
        XCTAssertEqual(OnDeviceChunker.capacity(contextSize: 8192), 171_770)
        XCTAssertEqual(OnDeviceChunker.materialCharacters(contextSize: 1000), OnDeviceChunker.minCharacters, "never less than a page or so")
    }

    func testPagesArePackedInOrderAndMarked() {
        let units = (1...3).map { MaterialUnit(text: OnDeviceFixtures.paragraph(100), page: $0) }
        let chunks = OnDeviceChunker.pack(units, maxCharacters: 250)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].firstPage, 1)
        XCTAssertEqual(chunks[0].lastPage, 2)
        XCTAssertEqual(chunks[1].firstPage, 3)
        XCTAssertTrue(chunks[0].text.hasPrefix("[Page 1]\n"))
        XCTAssertTrue(chunks[0].text.contains("[Page 2]\n"))
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 250 })
    }

    func testTextWithoutPagesHasNoPageMarks() {
        let chunks = OnDeviceChunker.pack([MaterialUnit(text: "Hello there", page: nil)], maxCharacters: 250)
        XCTAssertEqual(chunks.map(\.text), ["Hello there"])
        XCTAssertNil(chunks[0].firstPage)
    }

    func testAPageLongerThanAPartIsCutAtSentencesAndStillMarked() {
        let sentence = "This is one sentence about cells. "
        let unit = MaterialUnit(text: String(repeating: sentence, count: 40), page: 9)
        let chunks = OnDeviceChunker.pack([unit], maxCharacters: 300)
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 300 })
        XCTAssertTrue(chunks.allSatisfy { $0.firstPage == 9 && $0.lastPage == 9 })
        XCTAssertTrue(chunks.allSatisfy { $0.text.hasPrefix("[Page 9]") })
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.text.hasSuffix(".") }, "cut where a sentence ends")
    }

    func testTextWithNoPlaceToCutIsCutAnyway() {
        let pieces = OnDeviceChunker.cut(String(repeating: "x", count: 1000), into: 300)
        XCTAssertEqual(pieces.map(\.count), [300, 300, 300, 100])
    }

    func testCardsAreSharedOutByWeightWithAtLeastOneEach() {
        XCTAssertEqual(OnDeviceChunker.distribute(8, weights: [3, 1]), [6, 2])
        XCTAssertEqual(OnDeviceChunker.distribute(10, weights: [1, 1, 1]).reduce(0, +), 10)
        XCTAssertEqual(OnDeviceChunker.distribute(10, weights: [1, 1, 1]).min(), 3)
        XCTAssertEqual(OnDeviceChunker.distribute(4, weights: [100, 1, 1, 1]).min(), 1, "even a small part gets a card")
        XCTAssertEqual(OnDeviceChunker.distribute(4, weights: [100, 1, 1, 1]).reduce(0, +), 4)
        XCTAssertEqual(OnDeviceChunker.distribute(5, weights: [10]), [5])
        XCTAssertEqual(OnDeviceChunker.distribute(0, weights: [1, 2]), [0, 0])
    }

    func testPartsArePickedEvenlyAcrossTheMaterial() {
        XCTAssertEqual(OnDeviceChunker.spread([1, 2, 3, 4, 5], to: 2), [1, 5])
        XCTAssertEqual(OnDeviceChunker.spread([1, 2, 3, 4, 5], to: 3), [1, 3, 5])
        XCTAssertEqual(OnDeviceChunker.spread([1, 2, 3, 4, 5], to: 1), [1])
        XCTAssertEqual(OnDeviceChunker.spread([1, 2], to: 5), [1, 2], "never more than there are")
    }
}

final class OnDevicePlannerTests: XCTestCase {
    private func pages(_ count: Int, size: Int) -> [MaterialUnit] {
        (1...count).map { MaterialUnit(text: OnDeviceFixtures.paragraph(size), page: $0) }
    }

    func testALittleTextIsOneCallForAllTheCards() {
        let plan = OnDevicePlanner.plan(units: [MaterialUnit(text: OnDeviceFixtures.paragraph(500), page: nil)], images: [], cardCount: 5, contextSize: 8192)
        XCTAssertEqual(plan.calls.count, 1)
        XCTAssertEqual(plan.calls[0].cards, 5)
        XCTAssertFalse(plan.isCut)
    }

    func testManyCardsFromLittleMaterialAreSplitIntoCallsOfAtMostTwelve() {
        let plan = OnDevicePlanner.plan(units: pages(12, size: 1000), images: [], cardCount: 30, contextSize: 8192)
        XCTAssertGreaterThanOrEqual(plan.calls.count, 3)
        XCTAssertEqual(plan.calls.map(\.cards).reduce(0, +), 30)
        XCTAssertTrue(plan.calls.allSatisfy { $0.cards <= 12 }, "\(plan.calls.map(\.cards))")
        XCTAssertFalse(plan.isCut)
    }

    func testMoreMaterialThanFitsIsCutAndSaysSo() {
        let plan = OnDevicePlanner.plan(units: pages(100, size: 3000), images: [], cardCount: 20, contextSize: 8192)
        XCTAssertEqual(plan.calls.count, OnDeviceChunker.maxCalls)
        XCTAssertTrue(plan.isCut)
        XCTAssertLessThan(plan.usedCharacters, plan.totalCharacters)
        XCTAssertEqual(plan.calls.map(\.cards).reduce(0, +), 20)
        XCTAssertEqual(plan.calls.first?.chunk?.firstPage, 1, "from the start")
    }

    func testASmallerContextMakesMoreAndSmallerParts() {
        let small = OnDevicePlanner.plan(units: pages(20, size: 3000), images: [], cardCount: 20, contextSize: 4096)
        let large = OnDevicePlanner.plan(units: pages(20, size: 3000), images: [], cardCount: 20, contextSize: 8192)
        XCTAssertGreaterThan(small.calls.count, large.calls.count)
        XCTAssertTrue(small.calls.allSatisfy { ($0.chunk?.text.count ?? 0) <= 6_118 })
    }

    func testPicturesAreCallsOfTheirOwn() {
        let plan = OnDevicePlanner.plan(units: [MaterialUnit(text: "Notes", page: nil)], images: [Data([1]), Data([2])], cardCount: 9, contextSize: 8192)
        XCTAssertEqual(plan.calls.count, 3)
        XCTAssertEqual(plan.calls.compactMap { $0.chunk?.image }, [Data([1]), Data([2])])
        XCTAssertEqual(plan.calls.map(\.cards).reduce(0, +), 9)
    }

    func testNoMaterialMeansCallsForTheTopicAlone() {
        let plan = OnDevicePlanner.plan(units: [], images: [], cardCount: 25, contextSize: 8192)
        XCTAssertEqual(plan.calls.count, 3)
        XCTAssertTrue(plan.calls.allSatisfy { $0.chunk == nil })
        XCTAssertEqual(plan.calls.map(\.cards).reduce(0, +), 25)
    }

    func testFewerCardsThanPartsUsesPartsFromAcrossTheMaterial() {
        let plan = OnDevicePlanner.plan(units: pages(30, size: 4000), images: [], cardCount: 2, contextSize: 4096)
        XCTAssertEqual(plan.calls.count, 2)
        XCTAssertEqual(plan.calls.map(\.cards), [1, 1])
        XCTAssertLessThan(plan.calls[0].chunk?.firstPage ?? 99, plan.calls[1].chunk?.firstPage ?? 0)
    }
}

final class OnDeviceMaterialTests: XCTestCase {
    func testAPDFGivesItsPagesWithTheOriginalsNumbers() throws {
        let pdf = try OnDeviceFixtures.pdf(pages: ["First page words.", "Second page words."], firstPage: 40)
        let units = OnDeviceMaterial.units(from: pdf)
        XCTAssertEqual(units.map(\.page), [40, 41])
        XCTAssertTrue(units[0].text.contains("First page"))
    }

    func testAScanHasNoWords() {
        let blank = try? GenerationInputs.pdf(from: GenerationFixtures.pdfData(pages: 3), filename: "scan.pdf")
        XCTAssertEqual(blank.map(OnDeviceMaterial.characters(in:)), 0)
        XCTAssertTrue(OnDeviceMaterial.units(from: blank!).isEmpty)
    }

    func testPastedTextIsSplitIntoParagraphs() {
        let units = OnDeviceMaterial.units(from: TextSource(text: "One.\n\nTwo.\n\n\n\nThree.", name: "notes.md"))
        XCTAssertEqual(units.count, 3)
        XCTAssertEqual(units[0].text, "Text “notes.md”:\nOne.")
        XCTAssertEqual(units[1].text, "Two.")
        XCTAssertNil(units[0].page)
    }
}

// MARK: - The words said to the model

final class OnDevicePromptTests: XCTestCase {
    private let original = OnDeviceFixtures.request([OnDeviceFixtures.text("x")], count: 12, focus: "the ATP counts")

    func testACallHasTheMaterialThenWhatToMake() {
        let chunk = MaterialChunk(text: "[Page 3]\nGlycolysis gives 2 ATP.", firstPage: 3, lastPage: 3)
        let request = OnDevicePrompt.request(for: .init(chunk: chunk, cards: 4), original: original, avoid: [])
        XCTAssertEqual(request.instructions, GenerationPrompt.system)
        XCTAssertTrue(request.prompt.hasPrefix("Material:\n[Page 3]\nGlycolysis gives 2 ATP."))
        XCTAssertTrue(request.prompt.contains("Make 4 flashcards from the material above."), "its own share, not all 12")
        XCTAssertTrue(request.prompt.contains("What matters to me:\nthe ATP counts"))
        XCTAssertTrue(request.prompt.contains("[Page 12]"), "tells it how pages are marked")
        XCTAssertNil(request.image)
    }

    func testNoPageNoteWithoutPages() {
        let chunk = MaterialChunk(text: "Some notes.", firstPage: nil, lastPage: nil)
        let request = OnDevicePrompt.request(for: .init(chunk: chunk, cards: 2), original: original, avoid: [])
        XCTAssertFalse(request.prompt.contains("[Page"))
    }

    func testOnlyAFewFrontsAreNamedToAvoidAndEachIsCutShort() {
        let fronts = (1...60).map { "Front \($0) " + String(repeating: "x", count: 200) }
        let request = OnDevicePrompt.request(for: .init(chunk: MaterialChunk(text: "a"), cards: 2), original: original, avoid: fronts)
        let lines = request.prompt.components(separatedBy: "\n").filter { $0.hasPrefix("- Front") }
        XCTAssertEqual(lines.count, 25, "the context is small")
        XCTAssertTrue(lines.first?.hasPrefix("- Front 36") == true, "the most recent")
        XCTAssertTrue(lines.allSatisfy { $0.count <= 2 + 80 })
    }

    func testAPictureCallHasNoMaterialBlockAndCarriesTheImage() {
        let chunk = MaterialChunk(text: "", image: Data([9]))
        let request = OnDevicePrompt.request(for: .init(chunk: chunk, cards: 3), original: original, avoid: [])
        XCTAssertFalse(request.prompt.contains("Material:"))
        XCTAssertTrue(request.prompt.hasPrefix("Make 3 flashcards from the material above."))
        XCTAssertEqual(request.image, Data([9]))
    }

    func testNothingButTheFocusAsksAboutTheTopic() {
        let request = OnDevicePrompt.request(for: .init(chunk: nil, cards: 5), original: OnDeviceFixtures.request([], count: 5, focus: "Krebs"), avoid: [])
        XCTAssertTrue(request.prompt.hasPrefix("Make 5 flashcards about the topic"))
    }

    func testARefineKeepsItsOwnWords() {
        let task = GenerationTask.refine(instruction: "shorter", deckName: "Cells", cards: [RefineCard(front: "a", back: "b", sourcePage: nil)])
        let request = OnDevicePrompt.request(for: .init(chunk: nil, cards: 1), original: OnDeviceFixtures.request([OnDeviceFixtures.text("x")], task: task), avoid: [])
        XCTAssertTrue(request.prompt.hasPrefix("Here is the deck “Cells”"))
    }
}

// MARK: - Cards as they finish

final class OnDeviceTrackerTests: XCTestCase {
    private typealias Cards = [(String?, String?, Int?)]

    func testTheNameWaitsForTheCardsToStart() {
        var tracker = OnDeviceStreamTracker(limit: 10)
        XCTAssertTrue(tracker.update(OnDeviceFixtures.partial("Glyc", []), isFinal: false).isEmpty, "still being written")
        let events = tracker.update(OnDeviceFixtures.partial("Glycolysis", [("Q?", nil, nil)]), isFinal: false)
        XCTAssertEqual(events, [.deckName("Glycolysis")])
        XCTAssertTrue(tracker.update(OnDeviceFixtures.partial("Glycolysis", [("Q?", "A", 1)]), isFinal: false).isEmpty, "name only once")
    }

    func testACardIsDoneWhenTheNextOneBegins() {
        var tracker = OnDeviceStreamTracker(limit: 10)
        _ = tracker.update(OnDeviceFixtures.partial("N", [("Q1", "A", 3)]), isFinal: false)
        XCTAssertEqual(tracker.emitted, 0, "the only card may still be growing")
        let events = tracker.update(OnDeviceFixtures.partial("N", [("Q1", "A1", 3), ("Q2", nil, nil)]), isFinal: false)
        XCTAssertEqual(events, [.card(GeneratedCard(front: "Q1", back: "A1", sourcePage: 3))])
        let last = tracker.update(OnDeviceFixtures.partial("N", [("Q1", "A1", 3), ("Q2", "A2", nil)]), isFinal: true)
        XCTAssertEqual(last, [.card(GeneratedCard(front: "Q2", back: "A2", sourcePage: nil))], "the end finishes the last card")
    }

    func testAnEmptyOrHalfWrittenCardIsSkippedNotShown() {
        var tracker = OnDeviceStreamTracker(limit: 10)
        let cards: Cards = [("Q1", nil, nil), ("  ", "A", nil), ("Q3", "A3", 0)]
        let events = tracker.update(OnDeviceFixtures.partial("N", cards), isFinal: true)
        XCTAssertEqual(events, [.deckName("N"), .card(GeneratedCard(front: "Q3", back: "A3", sourcePage: nil))], "a page of 0 is no page")
    }

    func testNoMoreCardsThanAskedFor() {
        var tracker = OnDeviceStreamTracker(limit: 2)
        let cards: Cards = (1...5).map { ("Q\($0)", "A\($0)", nil) }
        let events = tracker.update(OnDeviceFixtures.partial(nil, cards), isFinal: true)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(tracker.emitted, 2)
    }

    func testTheNameCanBeLeftOut() {
        var tracker = OnDeviceStreamTracker(limit: 5)
        let events = tracker.update(OnDeviceFixtures.partial("Later part", [("Q", "A", nil)]), isFinal: true, wantsName: false)
        XCTAssertEqual(events, [.card(GeneratedCard(front: "Q", back: "A", sourcePage: nil))])
    }
}

final class OnDeviceCleanerTests: XCTestCase {
    func testTheNameOfAFieldIsTakenOutOfWhatTheModelWrote() {
        XCTAssertEqual(OnDeviceCleaner.clean("Glycolysis; net 2 ATP (sourcePage: 1)"), "Glycolysis; net 2 ATP")
        XCTAssertEqual(OnDeviceCleaner.clean("Cytosol [source page: 4]"), "Cytosol")
        XCTAssertEqual(OnDeviceCleaner.clean("2 ATP, sourcePage: 12"), "2 ATP")
        XCTAssertEqual(OnDeviceCleaner.clean("Two (sourcePage: nil) steps"), "Two steps")
        XCTAssertEqual(OnDeviceCleaner.clean("The source page of a book"), "The source page of a book", "ordinary words are left alone")
    }

    func testAPageStaysOnlyIfTheMaterialHadIt() {
        let card = GeneratedCard(front: "Q", back: "A", sourcePage: 5)
        XCTAssertEqual(OnDeviceCleaner.clean(card, pages: 4...6).sourcePage, 5)
        XCTAssertNil(OnDeviceCleaner.clean(card, pages: 8...9).sourcePage, "made up")
        XCTAssertNil(OnDeviceCleaner.clean(card, pages: nil).sourcePage, "there were no pages")
    }
}

// MARK: - The generator

final class AppleIntelligenceGeneratorTests: XCTestCase {
    private func make(
        _ scripts: [[FakeOnDeviceEngine.Step]], status: OnDeviceStatus = .available(contextSize: 8192)
    ) -> (AppleIntelligenceGenerator, FakeOnDeviceEngine) {
        let engine = FakeOnDeviceEngine(scripts)
        return (AppleIntelligenceGenerator(engine: engine, status: status), engine)
    }

    private func deck(_ name: String?, _ cards: [(String?, String?, Int?)]) -> FakeOnDeviceEngine.Step {
        .deck(OnDeviceFixtures.partial(name, cards))
    }

    private func cards(_ events: [GenerationEvent]) -> [GeneratedCard] {
        events.compactMap { if case .card(let card) = $0 { card } else { nil } }
    }

    func testOneShortTextOneCallNameThenCardsThenFinished() async {
        let (generator, engine) = make([[deck("Cells", [("Q1", "A1", nil), ("Q2", "A2", nil)])]])
        let result = await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text("Cells are small.")], count: 2)))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events, [
            .deckName("Cells"), .card(GeneratedCard(front: "Q1", back: "A1", sourcePage: nil)),
            .card(GeneratedCard(front: "Q2", back: "A2", sourcePage: nil)), .finished(nil),
        ])
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertTrue(engine.requests[0].prompt.contains("Cells are small."))
    }

    func testLongMaterialIsMadeIntoCardsPartByPartWithOneName() async {
        let first = OnDeviceFixtures.paragraph(4000, "alpha ")
        let second = OnDeviceFixtures.paragraph(4000, "beta ")
        let (generator, engine) = make([
            [deck("First Deck", [("Q1", "A1", nil), ("Q2", "A2", nil)])],
            [deck("Second Deck", [("Q3", "A3", nil), ("Q4", "A4", nil)])],
        ], status: .available(contextSize: 4096))
        let result = await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text(first + "\n\n" + second)], count: 4)))
        XCTAssertNil(result.error)
        XCTAssertEqual(engine.requests.count, 2)
        XCTAssertTrue(engine.requests[0].prompt.contains("alpha"))
        XCTAssertFalse(engine.requests[0].prompt.contains("beta"))
        XCTAssertTrue(engine.requests[1].prompt.contains("beta"))
        XCTAssertEqual(cards(result.events).map(\.front), ["Q1", "Q2", "Q3", "Q4"])
        XCTAssertEqual(result.events.filter { if case .deckName = $0 { true } else { false } }, [.deckName("First Deck")], "one name, from the first part")
        XCTAssertTrue(engine.requests[1].prompt.contains("- Q1\n- Q2"), "the second part is told what the first wrote")
        XCTAssertEqual(result.events.last, .finished(nil))
    }

    func testTheExistingDecksFrontsAreAvoidedToo() async {
        let (generator, engine) = make([[deck("N", [("Q", "A", nil)])]])
        _ = await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text("notes")], count: 1, existing: ["Already there"])))
        XCTAssertTrue(engine.requests[0].prompt.contains("- Already there"))
    }

    func testPageNumbersFollowThePDFAndMadeUpOnesAreDropped() async throws {
        let pdf = try OnDeviceFixtures.pdf(pages: ["Glycolysis words here.", "Krebs cycle words here."], firstPage: 10)
        let (generator, engine) = make([[deck("Cells", [("Q1", "A1 (sourcePage: 11)", 11), ("Q2", "A2", 99)])]])
        let result = await collect(generator.generate(OnDeviceFixtures.request([.pdf(pdf)], count: 2)))
        XCTAssertNil(result.error)
        XCTAssertEqual(cards(result.events), [
            GeneratedCard(front: "Q1", back: "A1", sourcePage: 11),
            GeneratedCard(front: "Q2", back: "A2", sourcePage: nil),
        ])
        XCTAssertTrue(engine.requests[0].prompt.contains("[Page 10]"))
        XCTAssertTrue(engine.requests[0].prompt.contains("[Page 11]"))
    }

    func testTextHasNoPagesSoAPageTheModelMakesUpIsDropped() async {
        let (generator, _) = make([[deck("N", [("Q", "A (sourcePage: 1)", 1)])]])
        let result = await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text("notes")], count: 1)))
        XCTAssertEqual(cards(result.events), [GeneratedCard(front: "Q", back: "A", sourcePage: nil)])
    }

    // MARK: Things it can't do

    func testAScannedPDFHasNoWordsToReadAndNothingIsAsked() async throws {
        let scan = try GenerationInputs.pdf(from: GenerationFixtures.pdfData(pages: 3), filename: "scan.pdf")
        let (generator, engine) = make([[]])
        let result = await collect(generator.generate(OnDeviceFixtures.request([.pdf(scan)])))
        XCTAssertEqual(result.error as? GenerationError, .noReadableText)
        XCTAssertTrue(engine.requests.isEmpty)
    }

    func testPicturesNeedAModelThatCanLookAtThem() async {
        let image = ImageSource(data: Data([1, 2]), mediaType: "image/jpeg", filename: "a.jpg")
        let (blind, engine) = make([[]], status: .available(supportsImages: false))
        let refused = await collect(blind.generate(OnDeviceFixtures.request([.image(image)])))
        XCTAssertEqual(refused.error as? GenerationError, .imagesNotSupported)
        XCTAssertTrue(engine.requests.isEmpty)

        let (sighted, seeing) = make([[deck("Board", [("Q", "A", nil)])]], status: .available(supportsImages: true))
        let result = await collect(sighted.generate(OnDeviceFixtures.request([.image(image)], count: 1)))
        XCTAssertNil(result.error)
        XCTAssertEqual(seeing.requests.first?.image, Data([1, 2]))
        XCTAssertFalse(seeing.requests[0].prompt.contains("Material:"))
        XCTAssertEqual(cards(result.events).count, 1)
    }

    func testAModelThatIsNotReadyAsksNothing() async {
        let (generator, engine) = make([[]], status: .unavailable(.appleIntelligenceOff))
        let result = await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text("x")])))
        XCTAssertEqual(result.error as? GenerationError, .onDeviceUnavailable)
        XCTAssertTrue(engine.requests.isEmpty)
    }

    func testFocusAloneMakesCardsAboutTheTopic() async {
        let (generator, engine) = make([[deck("Krebs", [("Q", "A", nil)])]])
        let result = await collect(generator.generate(OnDeviceFixtures.request([], count: 1, focus: "the Krebs cycle")))
        XCTAssertNil(result.error)
        XCTAssertTrue(engine.requests[0].prompt.contains("about the topic"))
        XCTAssertFalse(engine.requests[0].prompt.contains("Material:"))
    }

    // MARK: Failures

    func testWhatTheSystemSaysIsPutInPlainWords() {
        let cases: [(OnDeviceFailure, GenerationError)] = [
            (.contextExceeded, .tooLarge), (.guardrail, .refused), (.refusal, .refused),
            (.unsupportedLanguage, .languageNotSupported), (.assetsUnavailable, .onDeviceUnavailable),
            (.rateLimited, .rateLimited(retryAfter: nil)), (.busy, .overloaded), (.decoding, .badResponse), (.other, .badResponse),
        ]
        for (failure, expected) in cases { XCTAssertEqual(AppleIntelligenceGenerator.error(for: failure), expected, "\(failure)") }
    }

    func testAFailureKeepsTheCardsAlreadyShown() async {
        let (generator, _) = make([[deck("N", [("Q1", "A1", nil), ("Q2", nil, nil)]), .fail(.unsupportedLanguage)]])
        let result = await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text("hallo")], count: 3)))
        XCTAssertEqual(result.error as? GenerationError, .languageNotSupported)
        XCTAssertEqual(result.events, [.deckName("N"), .card(GeneratedCard(front: "Q1", back: "A1", sourcePage: nil))])
    }

    func testAPartTheSafetyChecksStopIsLeftOutAndTheRestGoesOn() async {
        let (generator, _) = make([
            [.fail(.guardrail)],
            [deck("N", [("Q", "A", nil)])],
        ], status: .available(contextSize: 4096))
        let text = OnDeviceFixtures.paragraph(4000, "alpha ") + "\n\n" + OnDeviceFixtures.paragraph(4000, "beta ")
        let result = await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text(text)], count: 2)))
        XCTAssertNil(result.error)
        XCTAssertEqual(cards(result.events).count, 1)
    }

    func testIfEveryPartIsStoppedItIsRefused() async {
        let (generator, _) = make([[.fail(.guardrail)], [.fail(.refusal)]], status: .available(contextSize: 4096))
        let text = OnDeviceFixtures.paragraph(4000, "alpha ") + "\n\n" + OnDeviceFixtures.paragraph(4000, "beta ")
        let result = await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text(text)], count: 2)))
        XCTAssertEqual(result.error as? GenerationError, .refused)
    }

    func testAPartThatIsTooLongIsCutInHalfAndTriedAgain() async {
        let (generator, engine) = make([
            [.fail(.contextExceeded)],
            [deck("N", [("Q1", "A1", nil)])],
            [deck("N", [("Q2", "A2", nil)])],
        ])
        let result = await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text(OnDeviceFixtures.paragraph(3000))], count: 2)))
        XCTAssertNil(result.error)
        XCTAssertEqual(engine.requests.count, 3)
        XCTAssertEqual(cards(result.events).map(\.front), ["Q1", "Q2"])
        let first = engine.requests[0].prompt.count, half = engine.requests[1].prompt.count
        XCTAssertLessThan(half, first)
    }

    func testAPartThatCannotBeCutAnyFurtherIsTooLarge() async {
        let (generator, engine) = make([[.fail(.contextExceeded)], [.fail(.contextExceeded)], [.fail(.contextExceeded)], [.fail(.contextExceeded)]])
        let result = await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text(OnDeviceFixtures.paragraph(3000))], count: 2)))
        XCTAssertEqual(result.error as? GenerationError, .tooLarge)
        XCTAssertLessThanOrEqual(engine.requests.count, 4)
    }

    func testAShortPartThatIsTooLongIsTooLargeAtOnce() async {
        let (generator, engine) = make([[.fail(.contextExceeded)]])
        let result = await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text("short")], count: 1)))
        XCTAssertEqual(result.error as? GenerationError, .tooLarge)
        XCTAssertEqual(engine.requests.count, 1)
    }

    // MARK: Changing cards

    func testARefineSendsTheCardsAndNoMaterial() async {
        let task = GenerationTask.refine(instruction: "shorter", deckName: "Cells", cards: [RefineCard(front: "Q", back: "A long answer", sourcePage: 2)])
        let (generator, engine) = make([[deck("Cells", [("Q", "A", nil)])]])
        let result = await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text(OnDeviceFixtures.paragraph(5000))], count: 1, task: task)))
        XCTAssertNil(result.error)
        XCTAssertEqual(engine.requests.count, 1, "one call, not one per part")
        XCTAssertFalse(engine.requests[0].prompt.contains("Material:"))
        XCTAssertTrue(engine.requests[0].prompt.contains("“shorter”"))
        XCTAssertEqual(cards(result.events).map(\.back), ["A"])
        XCTAssertEqual(result.events.last, .finished(nil))
    }

    func testARewriteIsOneCallForOneCard() async {
        let task = GenerationTask.replace(card: RefineCard(front: "Old?", back: "old", sourcePage: 4), deckName: "Cells")
        let (generator, engine) = make([[deck("Cells", [("New?", "new", nil)])]])
        let result = await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text("x")], count: 1, task: task, existing: ["Other"])))
        XCTAssertNil(result.error)
        XCTAssertTrue(engine.requests[0].prompt.contains("the person doesn't want this card"))
        XCTAssertTrue(engine.requests[0].prompt.contains("- Other"))
        XCTAssertEqual(cards(result.events).map(\.front), ["New?"])
    }

    // MARK: Stopping

    func testStoppingStopsTheModel() async {
        let engine = FakeOnDeviceEngine([[deck("N", [("Q1", "A1", nil), ("Q2", nil, nil)]), .hang]])
        let generator = AppleIntelligenceGenerator(engine: engine, status: .available())
        let task = Task { await collect(generator.generate(OnDeviceFixtures.request([OnDeviceFixtures.text("notes")], count: 5))) }
        let deadline = Date().addingTimeInterval(5)
        while engine.requests.isEmpty, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.events.contains(.deckName("N")))
        let end = Date().addingTimeInterval(5)
        while !engine.terminated, Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(engine.terminated, "the model was told to stop")
    }
}

// MARK: - In the composer

@MainActor
final class OnDeviceComposerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try PictureFixtures.tempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func rig(onDevice: OnDeviceStatus, anthropic: String? = nil) async -> ComposerRig {
        await ComposerRig.make(directory: directory, anthropic: anthropic, onDevice: onDevice)
    }

    func testItIsOnlyUsedWhenItWasChosen() async {
        let rig = await rig(onDevice: .available())
        rig.model.focus = "x"
        XCTAssertNil(rig.model.activeProvider, "free is no reason to switch to a smaller model")
        XCTAssertEqual(rig.model.readiness, .needsProvider)
        rig.ai.setDefaultProvider(.appleIntelligence)
        XCTAssertEqual(rig.model.activeProvider?.provider, .appleIntelligence)
        XCTAssertEqual(rig.model.activeProvider?.summary, "Apple Intelligence · on this Mac, free")
        XCTAssertEqual(rig.model.readiness, .ready)
    }

    func testItNeedsNoKeyToStartARun() async throws {
        let rig = await rig(onDevice: .available(contextSize: 8192))
        rig.ai.setDefaultProvider(.appleIntelligence)
        rig.model.focus = "x"
        let plan = try XCTUnwrap(rig.model.plan(decks: []))
        XCTAssertTrue(plan.makeGenerator() is AppleIntelligenceGenerator)
        XCTAssertEqual(plan.request.modelID, AIProvider.onDeviceModelID)
    }

    func testWhenItStopsBeingReadyTheComposerFallsBackToAKeyOrAsksAgain() async {
        let mutable = MutableOnDeviceModel(.available())
        let settings = SettingsStore(storage: SettingsStorage(directory: directory), onSaved: {})
        let ai = AIAccountStore(secrets: InMemorySecretStore(), client: AIModelClient(transport: FakeAPI().transport), cacheStorage: AIModelCacheStorage(directory: directory), settings: settings, onDeviceModel: mutable)
        let model = ComposerModel(settings: settings, ai: ai)
        ai.setDefaultProvider(.appleIntelligence)
        XCTAssertEqual(model.activeProvider?.provider, .appleIntelligence)
        mutable.set(.unavailable(.appleIntelligenceOff))
        ai.refreshOnDevice()
        XCTAssertNil(model.activeProvider)
        XCTAssertEqual(model.readiness, .needsProvider)
    }

    func testNoCostIsShown() async {
        let rig = await rig(onDevice: .available())
        rig.ai.setDefaultProvider(.appleIntelligence)
        rig.model.focus = "x"
        rig.probe.answer(.success(CostEstimate(inputTokens: 1, cardCount: 1, price: ModelPrice(inputPerMillion: 1, outputPerMillion: 1))))
        await rig.model.refreshCost(decks: [])
        XCTAssertEqual(rig.model.cost, .hidden, "there is no price for it")
        XCTAssertTrue(rig.probe.calls.isEmpty)
    }

    func testAScannedPDFIsMarkedWhenTheModelOnlyReadsWords() async throws {
        let rig = await rig(onDevice: .available(), anthropic: AIFixtures.anthropicDefault)
        let url = directory.appendingPathComponent("scan.pdf")
        try GenerationFixtures.pdfData(pages: 3).write(to: url)
        await rig.model.addFiles([url])
        XCTAssertTrue(rig.model.problems.isEmpty, "Anthropic reads scans")
        rig.ai.setDefaultProvider(.appleIntelligence)
        let id = try XCTUnwrap(rig.model.items.first?.id)
        XCTAssertEqual(rig.model.problems[id]?.message, GenerationError.noReadableText.message)
        XCTAssertEqual(rig.model.readiness, .hasProblems)

        let text = try OnDeviceFixtures.pdf(pages: ["A page with plenty of words on it."])
        let words = directory.appendingPathComponent("words.pdf")
        try text.data.write(to: words)
        rig.model.remove(id)
        await rig.model.addFiles([words])
        XCTAssertTrue(rig.model.problems.isEmpty)
        XCTAssertGreaterThan(rig.model.items.first?.textCharacters ?? 0, 20)
    }

    func testPicturesNeedAModelThatCanLookAtThem() async throws {
        let blind = await rig(onDevice: .available(supportsImages: false))
        blind.ai.setDefaultProvider(.appleIntelligence)
        await blind.model.add([.image(PictureFixtures.data(width: 64, height: 48), name: "a.png")])
        let id = try XCTUnwrap(blind.model.items.first?.id)
        XCTAssertTrue(try XCTUnwrap(blind.model.problems[id]?.message).hasPrefix("Apple Intelligence can't read pictures on this Mac"))

        let sighted = await rig(onDevice: .available(supportsImages: true))
        sighted.ai.setDefaultProvider(.appleIntelligence)
        await sighted.model.add([.image(PictureFixtures.data(width: 64, height: 48), name: "a.png")])
        XCTAssertTrue(sighted.model.problems.isEmpty)
    }

    func testMoreMaterialThanItReadsGetsAHeadsUpButIsNotBlocked() async throws {
        let rig = await rig(onDevice: .available(contextSize: 4096), anthropic: AIFixtures.anthropicDefault)
        let url = directory.appendingPathComponent("long.txt")
        try Data(OnDeviceFixtures.paragraph(90_000).utf8).write(to: url)
        await rig.model.addFiles([url])
        XCTAssertNil(rig.model.onDeviceNote, "only for the on-device model")
        rig.ai.setDefaultProvider(.appleIntelligence)
        let note = try XCTUnwrap(rig.model.onDeviceNote)
        XCTAssertTrue(note.hasPrefix("Apple Intelligence reads about"), note)
        XCTAssertTrue(note.contains("first part"))
        XCTAssertTrue(rig.model.problems.isEmpty)
        XCTAssertEqual(rig.model.readiness, .ready)
    }

    func testFocusAloneGetsAnHonestWarningAboutFacts() async throws {
        let rig = await rig(onDevice: .available(), anthropic: AIFixtures.anthropicDefault)
        rig.model.focus = "the Krebs cycle"
        XCTAssertNil(rig.model.onDeviceNote, "the companies' models are not warned about")
        rig.ai.setDefaultProvider(.appleIntelligence)
        let note = try XCTUnwrap(rig.model.onDeviceNote)
        XCTAssertTrue(note.contains("gets facts wrong"), note)
        await rig.model.add([.text("My notes about the Krebs cycle.")])
        XCTAssertNil(rig.model.onDeviceNote, "with material to read there is nothing to warn about")
    }

    func testNoHeadsUpForAShortText() async {
        let rig = await rig(onDevice: .available(contextSize: 4096))
        rig.ai.setDefaultProvider(.appleIntelligence)
        await rig.model.add([.text("A short note about cells.")])
        XCTAssertNil(rig.model.onDeviceNote)
    }

    func testTheDraftOffersTheRightFixesForTheNewErrors() async {
        let generator = ScriptedGenerator([[.hang]])
        let draft = GenerationDraft(plan: DraftFixtures.plan(generator), snapshot: DraftFixtures.snapshot())
        XCTAssertEqual(draft.fixes(for: .languageNotSupported, operation: .generate), [.startOver])
        XCTAssertEqual(draft.fixes(for: .noReadableText, operation: .generate), [.startOver])
        XCTAssertEqual(draft.fixes(for: .onDeviceUnavailable, operation: .generate), [.openSettings, .tryAgain])
        XCTAssertTrue(GenerationError.onDeviceUnavailable.message.contains("Apple Intelligence"))
        XCTAssertTrue(GenerationError.languageNotSupported.message.contains("language"))
    }
}

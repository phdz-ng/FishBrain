import AppKit
import XCTest

/// The Create with AI screen's state (FLAS-49): what has been added and what is wrong with it, the options,
/// the provider that would run, and the cost line. Nothing here goes online.

// MARK: - Rig

/// A composer wired to a real settings store and AI store with stubbed model lists.
@MainActor
struct ComposerRig {
    let settings: SettingsStore
    let ai: AIAccountStore
    let unsupported: UnsupportedModels
    let probe: EstimatorProbe
    let model: ComposerModel

    static let smallModels = #"{"data":[{"id":"claude-small-1","display_name":"Claude Small","max_input_tokens":200000,"max_tokens":64000,"capabilities":{"structured_outputs":{"supported":true},"image_input":{"supported":true},"effort":{"supported":true}}}],"has_more":false,"last_id":null}"#

    /// `anthropic` and `openAI` are the model lists the keys are checked with; nil means no key for that one.
    static func make(
        directory: URL, anthropic: String? = AIFixtures.anthropicDefault, openAI: String? = nil,
        generator: CardGenerator? = nil, onDevice: OnDeviceStatus = .unavailable(.needsNewerSystem)
    ) async -> ComposerRig {
        var replies: [FakeAPI.Reply] = []
        if let anthropic { replies.append(.json(200, anthropic)) }
        if let openAI { replies.append(.json(200, openAI)) }
        let settings = SettingsStore(storage: SettingsStorage(directory: directory), onSaved: {})
        let ai = AIAccountStore(
            secrets: InMemorySecretStore(), client: AIModelClient(transport: FakeAPI(replies).transport),
            cacheStorage: AIModelCacheStorage(directory: directory), settings: settings, onDeviceModel: FixedOnDeviceModel(value: onDevice)
        )
        if anthropic != nil { await ai.saveKey("sk-ant-key-0123456789abcdef", for: .anthropic) }
        if openAI != nil { await ai.saveKey("sk-openai-key-0123456789abcd", for: .openAI) }
        let unsupported = UnsupportedModels()
        let probe = EstimatorProbe()
        let model: ComposerModel
        if let generator {
            model = ComposerModel(settings: settings, ai: ai, unsupported: unsupported, costEstimator: probe.estimator, generatorFactory: { _, _ in generator })
        } else {
            model = ComposerModel(settings: settings, ai: ai, unsupported: unsupported, costEstimator: probe.estimator)
        }
        return ComposerRig(settings: settings, ai: ai, unsupported: unsupported, probe: probe, model: model)
    }
}

/// Stands in for the cost call: remembers what it was asked and answers as told.
final class EstimatorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(request: GenerationRequest, model: AIModel, key: String)] = []
    private var _result: Result<CostEstimate?, Error> = .success(nil)

    var calls: [(request: GenerationRequest, model: AIModel, key: String)] { lock.withLock { _calls } }
    func answer(_ result: Result<CostEstimate?, Error>) { lock.withLock { _result = result } }

    var estimator: CostEstimating {
        { [self] request, model, key in
            let result: Result<CostEstimate?, Error> = lock.withLock {
                _calls.append((request, model, key))
                return _result
            }
            return try result.get()
        }
    }
}

// MARK: - Tests

@MainActor
final class ComposerModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try PictureFixtures.tempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func make(anthropic: String? = AIFixtures.anthropicDefault, openAI: String? = nil) async -> ComposerRig {
        await ComposerRig.make(directory: directory, anthropic: anthropic, openAI: openAI)
    }

    // MARK: Ready or not

    func testWithoutAKeyTheScreenAsksToSetOneUp() async {
        let rig = await make(anthropic: nil)
        rig.model.focus = "glycolysis"
        XCTAssertNil(rig.model.activeProvider)
        XCTAssertEqual(rig.model.readiness, .needsProvider)
        XCTAssertNil(rig.model.plan(decks: []))
        XCTAssertFalse(rig.model.canGenerate)
    }

    func testNeedsASourceOrSomeFocus() async throws {
        let rig = await make()
        XCTAssertEqual(rig.model.readiness, .needsInput)
        rig.model.focus = "  \n "
        XCTAssertEqual(rig.model.readiness, .needsInput, "blanks are nothing")
        rig.model.focus = "the Krebs cycle"
        XCTAssertEqual(rig.model.readiness, .ready)
        rig.model.focus = ""
        await rig.model.add([.text("Some notes")])
        XCTAssertEqual(rig.model.readiness, .ready)
        let id = try XCTUnwrap(rig.model.items.first?.id)
        rig.model.remove(id)
        XCTAssertEqual(rig.model.readiness, .needsInput)
    }

    func testFocusAloneMakesARequestWithNoSources() async throws {
        let rig = await make()
        rig.model.focus = "  the Krebs cycle \n"
        let request = try XCTUnwrap(rig.model.request(decks: []))
        XCTAssertTrue(request.sources.isEmpty)
        XCTAssertEqual(request.focus, "the Krebs cycle")
        XCTAssertEqual(request.modelID, "claude-opus-5-5")
    }

    func testTheProviderIsTheDefaultOneWithAKey() async {
        let rig = await make(openAI: AIFixtures.openAIDefault)
        XCTAssertEqual(rig.model.activeProvider?.provider, .anthropic)
        XCTAssertEqual(rig.model.activeProvider?.summary, "Claude Opus 5.5 · your Anthropic key")
        rig.ai.setDefaultProvider(.openAI)
        XCTAssertEqual(rig.model.activeProvider?.provider, .openAI)
        XCTAssertEqual(rig.model.activeProvider?.model.id, "gpt-6-astra")
        rig.ai.removeKey(for: .openAI)
        XCTAssertEqual(rig.model.activeProvider?.provider, .anthropic, "falls back to one that has a key")
    }

    func testAModelThatHasAlreadyBeenTurnedDownBlocksGenerate() async {
        let rig = await make()
        rig.model.focus = "x"
        XCTAssertTrue(rig.model.canGenerate)
        rig.unsupported.mark("claude-opus-5-5", provider: .anthropic)
        XCTAssertEqual(rig.model.readiness, .modelCantMakeCards)
        XCTAssertFalse(rig.model.canGenerate)
    }

    // MARK: Adding

    func testEachKindOfFileMakesAChip() async throws {
        let rig = await make()
        let pdf = try write(GenerationFixtures.pdfData(pages: 3), "chapter.pdf")
        let png = try write(PictureFixtures.data(width: 300, height: 200), "photo.png")
        let heic = try write(PictureFixtures.data(width: 100, height: 100, type: .jpeg), "shot.jpg")
        let notes = try write(Data("one two three four".utf8), "notes.md")
        await rig.model.addFiles([pdf, png, heic, notes])

        XCTAssertEqual(rig.model.items.map(\.kind), [.pdf, .image, .image, .text])
        XCTAssertEqual(rig.model.items.map(\.name), ["chapter.pdf", "photo.png", "shot.jpg", "notes.md"])
        XCTAssertTrue(rig.model.items[0].detail.hasPrefix("3 pages · "), rig.model.items[0].detail)
        XCTAssertTrue(rig.model.items[1].detail.hasPrefix("Picture · "))
        XCTAssertEqual(rig.model.items[3].detail, "4 words")
        XCTAssertNotNil(rig.model.items[1].thumbnail, "a picture shows as a thumbnail")
        XCTAssertNil(rig.model.items[0].thumbnail)
        XCTAssertEqual(rig.model.readingCount, 0)
        XCTAssertTrue(rig.model.notices.isEmpty)
    }

    func testWhatCannotBeReadBecomesANoticeNotAChip() async throws {
        let rig = await make()
        let odd = try write(Data([1, 2, 3]), "program.xyz")
        let locked = try write(GenerationFixtures.pdfData(pages: 2, password: "secret"), "locked.pdf")
        let empty = try write(Data("   \n".utf8), "blank.txt")
        await rig.model.addFiles([odd, locked, empty])
        XCTAssertTrue(rig.model.items.isEmpty)
        XCTAssertEqual(rig.model.notices.map(\.text), [
            "“program.xyz” isn't a PDF, a picture or a text file FishBrain can use.",
            "“locked.pdf” is password protected. Remove the password and add it again.",
            "“blank.txt” has nothing in it to make cards from.",
        ])
        let first = rig.model.notices[0].id
        rig.model.dismissNotice(first)
        XCTAssertEqual(rig.model.notices.count, 2)
    }

    func testPastedTextIsAChipWithItsWordCount() async {
        let rig = await make()
        await rig.model.add([.text("  one two\nthree  ")])
        XCTAssertEqual(rig.model.items.first?.name, "Pasted text")
        XCTAssertEqual(rig.model.items.first?.detail, "3 words")
        XCTAssertEqual(rig.model.items.first?.accessibilityText, "Pasted text, 3 words")
        await rig.model.add([.text("   ")])
        XCTAssertEqual(rig.model.items.count, 1)
        XCTAssertEqual(rig.model.notices.count, 1)
    }

    func testWordCountsReadInThePersonsRegion() {
        XCTAssertEqual(ComposerFormat.words(1240, locale: Locale(identifier: "en_US")), "1,240 words")
        XCTAssertEqual(ComposerFormat.words(1, locale: Locale(identifier: "en_US")), "1 word")
        XCTAssertEqual(ComposerFormat.wordCount("a  b\n\nc\td"), 4)
    }

    func testAPastedPictureBecomesAChip() async {
        let rig = await make()
        await rig.model.add([.image(PictureFixtures.data(width: 64, height: 48), name: "Pasted picture")])
        XCTAssertEqual(rig.model.items.first?.kind, .image)
        XCTAssertEqual(rig.model.items.first?.name, "Pasted picture")
        await rig.model.add([.image(Data([1, 2]), name: "Pasted picture")])
        XCTAssertEqual(rig.model.notices.count, 1, "bytes that aren't a picture are turned down")
    }

    func testRemovingAChip() async throws {
        let rig = await make()
        await rig.model.add([.text("a b"), .text("c d")])
        let id = try XCTUnwrap(rig.model.items.first?.id)
        rig.model.remove(id)
        XCTAssertEqual(rig.model.items.count, 1)
        XCTAssertEqual(rig.model.items.first?.detail, "2 words")
    }

    // MARK: The clipboard and drops

    private func scratchPasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("fishbrain-test-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    func testPasteboardGivesFilesThenAPictureThenText() throws {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        board.setString("some words", forType: .string)
        XCTAssertEqual(IncomingSource.from(board), [.text("some words")])

        board.clearContents()
        let image = PictureFixtures.data(width: 20, height: 20)
        board.setData(image, forType: .png)
        board.setString("also text", forType: .string)
        XCTAssertEqual(IncomingSource.from(board), [.image(image, name: "Pasted picture")], "a picture wins over text")

        board.clearContents()
        let file = try write(Data("x".utf8), "a.txt")
        board.writeObjects([file as NSURL])
        board.setString("a.txt", forType: .string)
        XCTAssertEqual(IncomingSource.from(board), [.file(file)], "files win over everything")

        board.clearContents()
        XCTAssertTrue(IncomingSource.from(board).isEmpty)
        board.setString("  \n", forType: .string)
        XCTAssertTrue(IncomingSource.from(board).isEmpty, "blank text is nothing")
    }

    func testThePasteButtonSaysWhenThereIsNothingToPaste() async {
        let rig = await make()
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        await rig.model.addFromPasteboard(board)
        await rig.model.addFromPasteboard(board)
        XCTAssertEqual(rig.model.notices.count, 1, "said once")
        XCTAssertTrue(rig.model.notices[0].text.contains("nothing FishBrain can use"))
        board.setString("pasted notes here", forType: .string)
        await rig.model.addFromPasteboard(board)
        XCTAssertEqual(rig.model.items.first?.detail, "3 words")
    }

    func testDroppedItemsAreRead() async throws {
        let text = await IncomingSource.load(from: [NSItemProvider(object: "hello there" as NSString)])
        XCTAssertEqual(text, [.text("hello there")])

        let url = try write(Data("x".utf8), "dropped.txt")
        let file = await IncomingSource.load(from: [NSItemProvider(object: url as NSURL)])
        XCTAssertEqual(file, [.file(url)])

        let nothing = await IncomingSource.load(from: [NSItemProvider()])
        XCTAssertTrue(nothing.isEmpty)
    }

    // MARK: Limits

    func testAPDFOverTheLimitSaysSoAndOffersPages() async throws {
        let rig = await make()
        let long = try write(GenerationFixtures.pdfData(pages: 601), "book.pdf")
        await rig.model.addFiles([long])
        let id = try XCTUnwrap(rig.model.items.first?.id)
        let problem = try XCTUnwrap(rig.model.problems[id])
        XCTAssertEqual(problem.message, "This PDF has 601 pages. Choose up to 600.")
        XCTAssertTrue(problem.offersPageRange)
        XCTAssertEqual(rig.model.readiness, .hasProblems)

        await rig.model.setPages(1...600, for: id)
        XCTAssertTrue(rig.model.problems.isEmpty)
        XCTAssertEqual(rig.model.items.first?.pageRange, 1...600)
        XCTAssertTrue(try XCTUnwrap(rig.model.items.first?.detail).hasPrefix("Pages 1–600 of 601 · "))
        XCTAssertEqual(rig.model.readiness, .ready)
        guard case .pdf(let sent)? = rig.model.request(decks: [])?.sources.first else { return XCTFail("a PDF is sent") }
        XCTAssertEqual(sent.pageCount, 600)
        XCTAssertEqual(sent.originalPageCount, 601)

        await rig.model.setPages(nil, for: id)
        XCTAssertNil(rig.model.items.first?.pageRange, "all pages again")
        XCTAssertNotNil(rig.model.problems[id])
    }

    func testChoosingPagesKeepsPageNumbersOfTheOriginal() async throws {
        let rig = await make()
        await rig.model.addFiles([try write(GenerationFixtures.pdfData(pages: 20), "book.pdf")])
        let id = try XCTUnwrap(rig.model.items.first?.id)
        await rig.model.setPages(5...9, for: id)
        guard case .pdf(let sent)? = rig.model.items.first?.source else { return XCTFail("a PDF") }
        XCTAssertEqual(sent.firstPage, 5)
        XCTAssertEqual(sent.pageCount, 5)
        XCTAssertEqual(rig.model.items.first?.pageRange, 5...9)
        await rig.model.setPages(8...12, for: id) // from the whole PDF, not from the five pages
        XCTAssertEqual(rig.model.items.first?.pageRange, 8...12)
        await rig.model.setPages(18...25, for: id)
        XCTAssertEqual(rig.model.notices.map(\.text), [SourceError.badPageRange.message], "pages that aren't there")
        XCTAssertEqual(rig.model.items.first?.pageRange, 8...12, "left as it was")
    }

    func testAModelWithASmallWindowReadsFewerPages() async throws {
        let rig = await make(anthropic: ComposerRig.smallModels)
        XCTAssertEqual(rig.model.maxPDFPages, 100)
        await rig.model.addFiles([try write(GenerationFixtures.pdfData(pages: 101), "book.pdf")])
        let id = try XCTUnwrap(rig.model.items.first?.id)
        XCTAssertEqual(rig.model.problems[id]?.message, "This PDF has 101 pages. This model reads up to 100.")
        await rig.model.setPages(1...100, for: id)
        XCTAssertTrue(rig.model.problems.isEmpty)
    }

    func testPDFsThatAreTooLongTogetherAreFlaggedOnTheLongest() async throws {
        let rig = await make(anthropic: ComposerRig.smallModels)
        await rig.model.addFiles([
            try write(GenerationFixtures.pdfData(pages: 40), "a.pdf"),
            try write(GenerationFixtures.pdfData(pages: 70), "b.pdf"),
        ])
        let longest = try XCTUnwrap(rig.model.items.first { $0.name == "b.pdf" })
        let problems = rig.model.problems
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems[longest.id]?.message, "Together the PDFs have 110 pages; at most 100 can be sent at once. Choose fewer pages.")
        XCTAssertEqual(problems[longest.id]?.offersPageRange, true)
    }

    func testTooMuchOverallIsFlaggedOnTheBiggest() async throws {
        let rig = await make()
        let blob = Data(repeating: UInt8(ascii: "a"), count: 8_000_000)
        await rig.model.addFiles([
            try write(blob, "1.txt"), try write(blob, "2.txt"), try write(blob + Data("b".utf8), "3.txt"), try write(blob, "4.txt"),
        ])
        XCTAssertEqual(rig.model.items.count, 4)
        let problems = rig.model.problems
        XCTAssertEqual(problems.count, 1)
        let flagged = try XCTUnwrap(rig.model.items.first { problems[$0.id] != nil })
        XCTAssertEqual(flagged.name, "3.txt")
        XCTAssertTrue(try XCTUnwrap(problems[flagged.id]).message.contains("more than can be sent at once"))
        XCTAssertFalse(try XCTUnwrap(problems[flagged.id]).offersPageRange, "text has no pages")
        XCTAssertEqual(rig.model.readiness, .hasProblems)
    }

    func testPicturesNeedAModelThatCanReadThem() async throws {
        let rig = await make()
        await rig.model.add([.image(PictureFixtures.data(width: 64, height: 48), name: "a.png")])
        XCTAssertTrue(rig.model.problems.isEmpty)
        rig.ai.selectModel("claude-text-1", for: .anthropic)
        let id = try XCTUnwrap(rig.model.items.first?.id)
        XCTAssertEqual(rig.model.problems[id]?.message, GenerationError.imagesNotSupported.message)
        XCTAssertEqual(rig.model.problems[id]?.offersPageRange, false)
        XCTAssertEqual(rig.model.readiness, .hasProblems)
        rig.ai.selectModel("claude-opus-5-5", for: .anthropic)
        XCTAssertEqual(rig.model.readiness, .ready)
    }

    func testThePageRangePickerChecksWhatIsTyped() {
        XCTAssertNil(PageRangePicker.problem(from: 1, to: 600, pageCount: 840, limit: 600))
        XCTAssertEqual(PageRangePicker.problem(from: 1, to: 601, pageCount: 840, limit: 600), "Choose up to 600 pages.")
        XCTAssertEqual(PageRangePicker.problem(from: 0, to: 10, pageCount: 840, limit: 600), "Pages run from 1 to 840.")
        XCTAssertEqual(PageRangePicker.problem(from: 10, to: 5, pageCount: 840, limit: 600), "Pages run from 1 to 840.")
        XCTAssertEqual(PageRangePicker.problem(from: 800, to: 900, pageCount: 840, limit: 600), "Pages run from 1 to 840.")
        XCTAssertNil(PageRangePicker.problem(from: 5, to: 5, pageCount: 840, limit: 600))
    }

    // MARK: Options

    func testTheCountStartsFromSettingsAndCanBeChosen() async {
        let rig = await make()
        XCTAssertEqual(rig.model.cardCount, 20)
        XCTAssertFalse(rig.model.isCustomCount)
        rig.settings.ai.cardsPerRun = 30
        XCTAssertEqual(rig.model.cardCount, 30, "follows Settings until a count is chosen")
        rig.model.choosePreset(10)
        XCTAssertEqual(rig.model.cardCount, 10)
        rig.settings.ai.cardsPerRun = 50
        XCTAssertEqual(rig.model.cardCount, 10, "a chosen count stays")

        rig.model.chooseCustom()
        XCTAssertTrue(rig.model.isCustomCount, "Custom is shown even on a preset number")
        rig.model.cardCount = 37
        XCTAssertEqual(rig.model.cardCount, 37)
        rig.model.cardCount = 0
        XCTAssertEqual(rig.model.cardCount, 1)
        rig.model.cardCount = 500
        XCTAssertEqual(rig.model.cardCount, 100)
        rig.model.choosePreset(20)
        XCTAssertFalse(rig.model.isCustomCount)
    }

    func testANumberOutsideThePresetsShowsAsCustom() async {
        let rig = await make()
        rig.settings.ai.cardsPerRun = 25
        XCTAssertTrue(rig.model.isCustomCount)
        XCTAssertEqual(rig.model.cardCount, 25)
    }

    func testTheRequestFollowsTheForm() async throws {
        let rig = await make()
        await rig.model.add([.text("notes about cells")])
        rig.model.focus = " the ATP counts "
        rig.model.choosePreset(30)
        rig.model.style = .cloze
        rig.model.languageName = "German"
        let request = try XCTUnwrap(rig.model.request(decks: []))
        XCTAssertEqual(request.cardCount, 30)
        XCTAssertEqual(request.style, .cloze)
        XCTAssertEqual(request.language, .named("German"))
        XCTAssertEqual(request.focus, "the ATP counts")
        XCTAssertEqual(request.sources, [.text(TextSource(text: "notes about cells", name: nil))])
        XCTAssertTrue(request.existingFronts.isEmpty)
        rig.model.languageName = nil
        XCTAssertEqual(try XCTUnwrap(rig.model.request(decks: [])).language, .sameAsSource)
    }

    func testAnExistingDeckPassesItsFrontsAlong() async throws {
        let rig = await make()
        rig.model.focus = "x"
        let deck = Deck(name: "Bio", cards: [Card(front: "What is ATP?", back: "energy"), Card(front: "Where is DNA?", back: "nucleus")])
        rig.model.destination = .deck(deck.id)
        XCTAssertEqual(try XCTUnwrap(rig.model.request(decks: [deck])).existingFronts, ["What is ATP?", "Where is DNA?"])
        XCTAssertEqual(rig.model.plan(decks: [deck])?.destination, .deck(deck.id))

        XCTAssertEqual(rig.model.resolvedDestination(in: []), .newDeck, "the deck was deleted")
        XCTAssertEqual(rig.model.plan(decks: [])?.destination, .newDeck)
        XCTAssertTrue(try XCTUnwrap(rig.model.request(decks: [])).existingFronts.isEmpty)
    }

    func testThereAreLanguagesToChooseFrom() {
        XCTAssertTrue(ComposerModel.languages.contains("English"))
        XCTAssertTrue(ComposerModel.languages.contains("Japanese"))
        XCTAssertEqual(Set(ComposerModel.languages).count, ComposerModel.languages.count, "no repeats")
    }

    // MARK: Starting a run

    func testThePlanMakesTheGeneratorOfTheProviderInUse() async throws {
        let rig = await make(openAI: AIFixtures.openAIDefault)
        rig.model.focus = "x"
        let anthropic = try XCTUnwrap(rig.model.plan(decks: []))
        XCTAssertTrue(anthropic.makeGenerator() is AnthropicCardGenerator)
        XCTAssertEqual(anthropic.provider.model.id, "claude-opus-5-5")
        XCTAssertEqual(anthropic.request.modelID, "claude-opus-5-5")

        rig.ai.setDefaultProvider(.openAI)
        let openAI = try XCTUnwrap(rig.model.plan(decks: []))
        XCTAssertTrue(openAI.makeGenerator() is OpenAICardGenerator)
        XCTAssertEqual(openAI.request.modelID, "gpt-6-astra")
    }

    func testThereIsNoPlanUntilItIsReady() async throws {
        let rig = await make()
        XCTAssertNil(rig.model.plan(decks: []))
        await rig.model.add([.image(PictureFixtures.data(width: 64, height: 48), name: "a.png")])
        rig.ai.selectModel("claude-text-1", for: .anthropic)
        XCTAssertNil(rig.model.plan(decks: []), "a chip has a problem")
    }

    func testResetEmptiesTheFormForTheNextVisit() async {
        let rig = await make()
        await rig.model.add([.text("notes")])
        rig.model.focus = "x"
        rig.model.style = .cloze
        rig.model.languageName = "French"
        rig.model.destination = .deck(UUID())
        rig.model.choosePreset(50)
        rig.model.reset()
        XCTAssertTrue(rig.model.items.isEmpty)
        XCTAssertEqual(rig.model.focus, "")
        XCTAssertEqual(rig.model.style, .questionAnswer)
        XCTAssertNil(rig.model.languageName)
        XCTAssertEqual(rig.model.destination, .newDeck)
        XCTAssertEqual(rig.model.cardCount, 20, "back to the default from Settings")
        XCTAssertEqual(rig.model.readiness, .needsInput)
    }

    // MARK: Cost

    private func estimate(_ low: Double = 0.2) -> CostEstimate {
        CostEstimate(inputTokens: 10_000, cardCount: 20, price: ModelPrice(inputPerMillion: 4, outputPerMillion: 20))
    }

    func testTheCostIsAskedForWhenReadyAndShown() async throws {
        let rig = await make()
        rig.probe.answer(.success(estimate()))
        rig.model.focus = "x"
        await rig.model.refreshCost(decks: [])
        XCTAssertEqual(rig.model.cost, .estimate(estimate()))
        let call = try XCTUnwrap(rig.probe.calls.first)
        XCTAssertEqual(call.model.id, "claude-opus-5-5")
        XCTAssertEqual(call.key, "sk-ant-key-0123456789abcdef")
        XCTAssertEqual(call.request.focus, "x")
    }

    func testNoCostWhenTheSettingIsOff() async {
        let rig = await make()
        rig.probe.answer(.success(estimate()))
        rig.model.focus = "x"
        await rig.model.refreshCost(decks: [])
        rig.settings.ai.showsCostEstimate = false
        await rig.model.refreshCost(decks: [])
        XCTAssertEqual(rig.model.cost, .hidden)
        XCTAssertEqual(rig.probe.calls.count, 1, "not asked again with the setting off")
    }

    func testNoCostWhenThePriceIsNotKnown() async {
        let json = AIFixtures.anthropicPage([("claude-mystery-9", "Mystery", true, true)])
        let rig = await make(anthropic: json)
        rig.probe.answer(.success(estimate()))
        rig.model.focus = "x"
        XCTAssertEqual(rig.model.activeProvider?.model.id, "claude-mystery-9")
        await rig.model.refreshCost(decks: [])
        XCTAssertEqual(rig.model.cost, .hidden)
        XCTAssertTrue(rig.probe.calls.isEmpty, "nothing is sent for a price that isn't known")
    }

    func testNoCostUntilThereIsSomethingToGenerateFrom() async {
        let rig = await make()
        rig.probe.answer(.success(estimate()))
        await rig.model.refreshCost(decks: [])
        XCTAssertEqual(rig.model.cost, .hidden)
        XCTAssertTrue(rig.probe.calls.isEmpty)
    }

    func testACostThatCannotBeWorkedOutShowsNothingAndDoesNotBlock() async {
        let rig = await make()
        rig.model.focus = "x"
        rig.probe.answer(.failure(GenerationError.network))
        await rig.model.refreshCost(decks: [])
        XCTAssertEqual(rig.model.cost, .hidden)
        XCTAssertTrue(rig.model.canGenerate)
        rig.probe.answer(.success(nil))
        await rig.model.refreshCost(decks: [])
        XCTAssertEqual(rig.model.cost, .hidden)
    }

    func testTheCostKeyChangesWithWhatChangesTheCost() async throws {
        let rig = await make()
        let base = rig.model.costKey(decks: [])
        XCTAssertEqual(rig.model.costKey(decks: []), base, "stable")
        rig.model.focus = "a"
        let withFocus = rig.model.costKey(decks: [])
        XCTAssertNotEqual(withFocus, base)
        rig.model.choosePreset(50)
        let withCount = rig.model.costKey(decks: [])
        XCTAssertNotEqual(withCount, withFocus)
        rig.model.style = .cloze
        XCTAssertNotEqual(rig.model.costKey(decks: []), withCount)
        await rig.model.add([.text("notes")])
        let withItem = rig.model.costKey(decks: [])
        rig.settings.ai.showsCostEstimate = false
        XCTAssertNotEqual(rig.model.costKey(decks: []), withItem)
    }

    // MARK: Prompt

    func testAFocusOnlyRunSaysThereIsNoMaterial() {
        let none = GenerationRequest(sources: [], focus: "the Krebs cycle", cardCount: 5, modelID: "m")
        let text = GenerationPrompt.instructions(for: none)
        XCTAssertTrue(text.hasPrefix("Make 5 flashcards about the topic"), text)
        XCTAssertTrue(text.contains("No material is attached"))
        XCTAssertFalse(text.contains("from the material above"))
        XCTAssertTrue(text.contains("the Krebs cycle"))

        let some = GenerationRequest(sources: [.text(TextSource(text: "t", name: nil))], focus: "", cardCount: 1, modelID: "m")
        XCTAssertTrue(GenerationPrompt.instructions(for: some).hasPrefix("Make 1 flashcard from the material above."))
    }
}

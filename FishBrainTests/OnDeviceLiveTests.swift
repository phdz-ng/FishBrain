import AppKit
import CoreText
import UniformTypeIdentifiers
import XCTest

/// Talks to the real model on this Mac. Skipped unless asked for, so a normal run (and CI) never does:
///
///     TEST_RUNNER_FISHBRAIN_LIVE_ON_DEVICE=1 xcodebuild test ... -only-testing:FishBrainTests/OnDeviceLiveTests
final class OnDeviceLiveTests: XCTestCase {
    private func requireLive() throws -> OnDeviceStatus {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FISHBRAIN_LIVE_ON_DEVICE"] == "1", "Set FISHBRAIN_LIVE_ON_DEVICE=1 to use the real model.")
        let status = SystemOnDeviceModel().status()
        try XCTSkipUnless(status.isAvailable, "Apple Intelligence isn't available on this Mac: \(status.detail ?? "").")
        return status
    }

    private func run(_ request: GenerationRequest, status: OnDeviceStatus) async -> (events: [GenerationEvent], error: Error?) {
        await collect(AppleIntelligenceGenerator(engine: FoundationModelsEngine(), status: status).generate(request))
    }

    func testTheRealModelMakesCardsFromText() async throws {
        let status = try requireLive()
        print("LIVE status:", status)
        let text = """
        Glycolysis is the first stage of cellular respiration. It takes place in the cytosol and breaks one molecule of glucose into two molecules of pyruvate. \
        The pathway uses 2 ATP early on and makes 4 ATP, so the net gain is 2 ATP. It also makes 2 NADH. Glycolysis does not need oxygen.
        After glycolysis, pyruvate enters the mitochondria, where it is turned into acetyl CoA. The citric acid cycle then runs in the mitochondrial matrix. \
        Each turn makes 3 NADH, 1 FADH2 and 1 ATP, and the cycle turns twice for each glucose.
        """
        let request = GenerationRequest(sources: [.text(TextSource(text: text, name: nil))], focus: "ATP counts", cardCount: 4, modelID: AIProvider.onDeviceModelID)
        let start = Date()
        let result = await run(request, status: status)
        print("LIVE took:", Date().timeIntervalSince(start), "s")
        for event in result.events { print("LIVE event:", event) }
        XCTAssertNil(result.error)
        let cards = result.events.compactMap { event -> GeneratedCard? in if case .card(let card) = event { card } else { nil } }
        XCTAssertFalse(cards.isEmpty, "the model wrote cards")
        XCTAssertLessThanOrEqual(cards.count, 4)
        XCTAssertTrue(result.events.contains { if case .deckName = $0 { true } else { false } })
        XCTAssertTrue(result.events.contains { if case .finished = $0 { true } else { false } })
    }

    func testTheRealModelMakesCardsFromAPDFWithPageNumbers() async throws {
        let status = try requireLive()
        let pdf = try OnDeviceFixtures.pdf(pages: [
            "Page one is about glycolysis. Glycolysis happens in the cytosol and gives a net gain of 2 ATP per glucose.",
            "Page two is about the citric acid cycle. It runs in the mitochondrial matrix and turns twice for each glucose.",
        ])
        let request = GenerationRequest(sources: [.pdf(pdf)], cardCount: 2, modelID: AIProvider.onDeviceModelID)
        let result = await run(request, status: status)
        for event in result.events { print("LIVE pdf event:", event) }
        XCTAssertNil(result.error)
        let cards = result.events.compactMap { event -> GeneratedCard? in if case .card(let card) = event { card } else { nil } }
        XCTAssertFalse(cards.isEmpty)
        XCTAssertTrue(cards.contains { $0.sourcePage != nil }, "page marks were followed")
    }

    func testTheRealModelReadsAPicture() async throws {
        let status = try requireLive()
        try XCTSkipUnless(status.supportsImages, "this Mac's model can't look at pictures")
        let image = try pictureOfWords(["Glycolysis happens in the cytosol.", "It makes a net gain of 2 ATP."])
        let request = GenerationRequest(sources: [.image(image)], cardCount: 2, modelID: AIProvider.onDeviceModelID)
        let result = await run(request, status: status)
        for event in result.events { print("LIVE picture event:", event) }
        XCTAssertNil(result.error)
        let cards = result.events.compactMap { event -> GeneratedCard? in if case .card(let card) = event { card } else { nil } }
        XCTAssertFalse(cards.isEmpty, "it made cards from what the picture says")
        let all = cards.map { $0.front + " " + $0.back }.joined(separator: " ").lowercased()
        XCTAssertTrue(all.contains("glycolysis") || all.contains("atp") || all.contains("cytosol"), all)
    }

    func testTheRealModelCutsLongTextIntoParts() async throws {
        let status = try requireLive()
        let topics = ["glycolysis in the cytosol", "the citric acid cycle in the matrix", "the electron transport chain in the inner membrane",
                      "fermentation without oxygen", "photosynthesis in the chloroplast", "the Calvin cycle in the stroma"]
        let text = topics.map { topic in
            (1...12).map { "Fact \($0) about \(topic): it is one of the stages that cells use to turn energy from food or light into ATP, and scientists have studied it for many decades." }
                .joined(separator: " ")
        }.joined(separator: "\n\n")
        let padded = text + "\n\n" + String(repeating: "More background about cells. ", count: 800)
        print("LIVE long text characters:", padded.count, "context:", status.contextSize)
        let request = GenerationRequest(sources: [.text(TextSource(text: padded, name: nil))], cardCount: 6, modelID: AIProvider.onDeviceModelID)
        let start = Date()
        let result = await run(request, status: status)
        print("LIVE long took:", Date().timeIntervalSince(start), "s")
        for event in result.events { print("LIVE long event:", event) }
        XCTAssertNil(result.error)
        let cards = result.events.compactMap { event -> GeneratedCard? in if case .card(let card) = event { card } else { nil } }
        XCTAssertGreaterThanOrEqual(cards.count, 3)
        XCTAssertLessThanOrEqual(cards.count, 6)
        XCTAssertEqual(Set(cards.map(\.front)).count, cards.count, "no card twice")
    }

    private func pictureOfWords(_ lines: [String]) throws -> ImageSource {
        let width = 900, height = 300
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: 30, y: height - 100 - index * 80)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return try GenerationInputs.image(from: data as Data, filename: "board.png")
    }
}

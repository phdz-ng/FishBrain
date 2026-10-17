import XCTest

/// Making cards with OpenAI (FLAS-48): the Responses API request, the streamed answer, and every way a call
/// can fail. Nothing here goes online: answers are stubbed (see `FakeStreamingAPI`).

// MARK: - Fixtures

enum OpenAIFixtures {
    static let astra = AIModel(provider: .openAI, id: "gpt-6-astra", displayName: "gpt-6-astra", created: nil)

    static func request(images: Bool = false, pdfPages: Int = 2, cards: Int = 20, pdfData: Data = AnthropicFixtures.pdfBytes) -> GenerationRequest {
        var sources: [GenerationSource] = [
            .pdf(PDFSource(data: pdfData, filename: "chapter9.pdf", pageCount: pdfPages)),
            .text(TextSource(text: "Notes", name: nil)),
        ]
        if images { sources.append(.image(ImageSource(data: Data([1, 2, 3]), mediaType: "image/jpeg", filename: "a.jpg"))) }
        return GenerationRequest(sources: sources, cardCount: cards, modelID: "gpt-6-astra")
    }

    static func urlRequest(_ request: GenerationRequest = request(), key: String = "sk-test") throws -> URLRequest {
        try OpenAIRequestBuilder(modelID: "gpt-6-astra").urlRequest(for: request, apiKey: key)
    }

    // MARK: Recorded stream

    static func textDelta(_ text: String, sequence: Int = 5) -> String {
        #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":1,"content_index":0,"delta":\#(AnthropicFixtures.quoted(text)),"logprobs":[],"sequence_number":\#(sequence)}"#
    }

    static let usage = #"{"input_tokens":1200,"output_tokens":90,"total_tokens":1290}"#

    static func completed(refusalContent: Bool = false) -> String {
        let content = refusalContent ? #"{"type":"refusal","refusal":"No."}"# : #"{"type":"output_text","text":"..."}"#
        return #"{"type":"response.completed","sequence_number":99,"response":{"id":"resp_1","status":"completed","usage":\#(usage),"output":[{"type":"reasoning"},{"type":"message","content":[\#(content)]}]}}"#
    }

    static func incomplete(_ reason: String) -> String {
        #"{"type":"response.incomplete","sequence_number":99,"response":{"id":"resp_1","status":"incomplete","incomplete_details":{"reason":"\#(reason)"},"usage":\#(usage)}}"#
    }

    /// What comes before the text: the response is created, then a reasoning item, then the message.
    static let beginning = [
        #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_1","status":"in_progress"}}"#,
        #"{"type":"response.in_progress","sequence_number":1,"response":{"id":"resp_1","status":"in_progress"}}"#,
        #"{"type":"response.output_item.added","sequence_number":2,"output_index":0,"item":{"type":"reasoning","id":"rs_1"}}"#,
        #"{"type":"response.output_item.done","sequence_number":3,"output_index":0,"item":{"type":"reasoning","id":"rs_1"}}"#,
        #"{"type":"response.output_item.added","sequence_number":4,"output_index":1,"item":{"type":"message","id":"msg_1","content":[]}}"#,
        #"{"type":"response.content_part.added","sequence_number":4,"output_index":1,"content_index":0,"part":{"type":"output_text","text":""}}"#,
    ]

    static func stream(
        text: String = GenerationFixtures.deckJSON, chunkSizes: [Int] = [7, 3, 11], ending: String? = completed()
    ) -> [String] {
        var payloads = beginning
        payloads += GenerationFixtures.chunks(text, sizes: chunkSizes).enumerated().map { textDelta($0.element, sequence: 5 + $0.offset) }
        payloads.append(#"{"type":"response.output_text.done","sequence_number":98,"output_index":1,"content_index":0,"text":"..."}"#)
        if let ending { payloads.append(ending) }
        return lines(payloads)
    }

    static func lines(_ payloads: [String]) -> [String] { AnthropicFixtures.lines(payloads) }

    static var expectedEvents: [GenerationEvent] {
        let deck = GenerationFixtures.expectedDeck
        return [.deckName(deck.deckName)] + deck.cards.map(GenerationEvent.card) + [.finished(AnthropicFixtures.finishedUsage)]
    }

    static func errorBody(code: String? = nil, type: String = "invalid_request_error", param: String? = nil, message: String) -> [String] {
        let codeText = code.map { AnthropicFixtures.quoted($0) } ?? "null", paramText = param.map { AnthropicFixtures.quoted($0) } ?? "null"
        return [#"{"error":{"message":\#(AnthropicFixtures.quoted(message)),"type":"\#(type)","param":\#(paramText),"code":\#(codeText)}}"#]
    }
}

// MARK: - The request

final class OpenAIRequestTests: XCTestCase {
    /// The exact body, member by member, with the schema in the order it was written.
    func testBodySnapshot() throws {
        let request = OpenAIFixtures.request(images: true)
        let body = try OpenAIRequestBuilder(modelID: "gpt-6-astra").body(for: request).text
        let q = AnthropicFixtures.quoted
        let pdf = AnthropicFixtures.pdfBytes.base64EncodedString(), image = Data([1, 2, 3]).base64EncodedString()
        let expected = #"{"model":"gpt-6-astra","stream":true,"store":false,"max_output_tokens":32000,"instructions":\#(q(GenerationPrompt.system)),"input":[{"role":"user","content":[{"type":"input_file","filename":"chapter9.pdf","file_data":"data:application/pdf;base64,\#(pdf)"},{"type":"input_image","image_url":"data:image/jpeg;base64,\#(image)","detail":"auto"},{"type":"input_text","text":\#(q(GenerationPrompt.textBlock(TextSource(text: "Notes", name: nil))))},{"type":"input_text","text":\#(q(GenerationPrompt.instructions(for: request)))}]}],"text":{"format":{"type":"json_schema","name":"flashcard_deck","strict":true,"schema":\#(CardSchema.schema.text)}}}"#
        XCTAssertEqual(body, expected)
    }

    func testSchemaKeepsDeckNameFirst() throws {
        let body = try OpenAIFixtures.urlRequest().httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let name = try XCTUnwrap(body.range(of: #""deckName""#)), cards = try XCTUnwrap(body.range(of: #""cards""#))
        XCTAssertLessThan(name.lowerBound, cards.lowerBound)
    }

    func testStrictSchemaRulesHold() {
        XCTAssertEqual(CardSchema.violations(), [], "every object closed and every property required")
    }

    func testResponsesAPIWithBearerKeyInAHeaderOnly() throws {
        let key = "sk-secret-1234"
        let urlRequest = try OpenAIFixtures.urlRequest(key: key)
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse(urlRequest.url!.absoluteString.contains(key))
        XCTAssertFalse(AnthropicFixtures.bodyText(urlRequest).contains(key))
    }

    func testNothingIsStoredAndNothingIsSampled() throws {
        let body = AnthropicFixtures.body(try OpenAIFixtures.urlRequest())
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 32_000)
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["messages"], "the Responses API, not Chat Completions")
        let format = ((body["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format?["strict"] as? Bool, true)
        XCTAssertEqual(format?["name"] as? String, "flashcard_deck")
    }

    func testDocumentsAndPicturesComeBeforeTheText() throws {
        let body = AnthropicFixtures.body(try OpenAIFixtures.urlRequest(OpenAIFixtures.request(images: true)))
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["role"] as? String }, ["user"])
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["input_file", "input_image", "input_text", "input_text"])
        XCTAssertFalse((content[0]["file_data"] as? String ?? "").contains("\n"), "base64 without newlines")
    }

    func testAPDFWithoutAFilenameStillGetsOne() throws {
        let request = GenerationRequest(sources: [.pdf(PDFSource(data: Data([1]), filename: "", pageCount: 1))], modelID: "gpt-6-astra")
        let content = try XCTUnwrap(((AnthropicFixtures.body(try OpenAIFixtures.urlRequest(request))["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["filename"] as? String, "document.pdf")
    }

    func testTooMuchIsTurnedDownBeforeAnythingIsSent() {
        XCTAssertThrowsError(try OpenAIFixtures.urlRequest(OpenAIFixtures.request(pdfPages: 601))) {
            XCTAssertEqual($0 as? GenerationError, .tooLarge)
        }
        let big = Data(count: 24 * 1024 * 1024) // about 32 MB once it is base64
        XCTAssertThrowsError(try OpenAIFixtures.urlRequest(OpenAIFixtures.request(pdfData: big))) {
            XCTAssertEqual($0 as? GenerationError, .tooLarge)
        }
    }
}

// MARK: - The answer

final class OpenAIStreamTests: XCTestCase {
    private func run(
        _ replies: [FakeStreamingAPI.Reply], request: GenerationRequest = OpenAIFixtures.request(),
        unsupported: UnsupportedModels = UnsupportedModels()
    ) async -> (api: FakeStreamingAPI, events: [GenerationEvent], error: Error?) {
        let api = FakeStreamingAPI(replies)
        let generator = OpenAICardGenerator(apiKey: "sk-test", model: OpenAIFixtures.astra, transport: api.transport, retryDelay: 0, unsupported: unsupported)
        let result = await collect(generator.generate(request))
        return (api, result.events, result.error)
    }

    /// A reasoning item before the message, chunks that fall anywhere: the name, the cards, then the tokens.
    func testRecordedStreamGivesNameCardsAndUsage() async {
        for sizes in [[7, 3, 11], [1], [500]] {
            let result = await run([.ok(OpenAIFixtures.stream(chunkSizes: sizes))])
            XCTAssertNil(result.error)
            XCTAssertEqual(result.events, OpenAIFixtures.expectedEvents, "chunks \(sizes)")
        }
    }

    func testCardsAreReportedBeforeTheAnswerEnds() {
        let reader = OpenAIStreamReader()
        var seen: [GenerationEvent] = []
        for line in OpenAIFixtures.stream(ending: nil) where line.hasPrefix("data: ") {
            seen += (try? reader.handle(payload: String(line.dropFirst(6)))) ?? []
        }
        XCTAssertEqual(seen.count, 4, "the name and three cards, before the response is completed")
        XCTAssertFalse(reader.isStopped)
    }

    func testUnknownEventsAreSkipped() async {
        let lines = OpenAIFixtures.lines([#"{"type":"response.something_new","x":1}"#, "not json at all"]) + OpenAIFixtures.stream()
        let result = await run([.ok(lines)])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events, OpenAIFixtures.expectedEvents)
    }

    func testOneRequestIsMade() async {
        let result = await run([.ok(OpenAIFixtures.stream())])
        XCTAssertEqual(result.api.requests.count, 1)
    }

    // MARK: Ending

    func testARefusalDeltaIsRefusedAfterTheTokensUsed() async {
        let lines = OpenAIFixtures.lines(OpenAIFixtures.beginning + [
            #"{"type":"response.refusal.delta","item_id":"msg_1","output_index":1,"content_index":0,"delta":"I can't help","sequence_number":5}"#,
            OpenAIFixtures.completed(refusalContent: true),
        ])
        let result = await run([.ok(lines)])
        XCTAssertEqual(result.error as? GenerationError, .refused)
        XCTAssertEqual(result.events, [.finished(AnthropicFixtures.finishedUsage)])
    }

    func testRefusalContentInTheFinishedResponseIsRefusedToo() async {
        let result = await run([.ok(OpenAIFixtures.stream(text: "", ending: OpenAIFixtures.completed(refusalContent: true)))])
        XCTAssertEqual(result.error as? GenerationError, .refused)
    }

    func testMaxOutputTokensKeepsTheCardsAndSaysTruncated() async {
        let partial = #"{"deckName":"Cells","cards":[{"front":"A","back":"B","sourcePage":1},{"front":"C","ba"#
        let result = await run([.ok(OpenAIFixtures.stream(text: partial, ending: OpenAIFixtures.incomplete("max_output_tokens")))])
        XCTAssertEqual(result.error as? GenerationError, .truncated)
        XCTAssertEqual(result.events, [
            .deckName("Cells"), .card(GeneratedCard(front: "A", back: "B", sourcePage: 1)),
            .finished(AnthropicFixtures.finishedUsage),
        ])
    }

    func testContentFilterIsRefused() async {
        let result = await run([.ok(OpenAIFixtures.stream(text: "", ending: OpenAIFixtures.incomplete("content_filter")))])
        XCTAssertEqual(result.error as? GenerationError, .refused)
        XCTAssertEqual(result.events, [.finished(AnthropicFixtures.finishedUsage)])
    }

    func testAnotherIncompleteReasonIsBadResponse() async {
        let result = await run([.ok(OpenAIFixtures.stream(text: "", ending: OpenAIFixtures.incomplete("steered")))])
        XCTAssertEqual(result.error as? GenerationError, .badResponse)
    }

    func testAnAnswerThatIsNotADeckIsBadResponse() async {
        let result = await run([.ok(OpenAIFixtures.stream(text: "Sorry, I can't."))])
        XCTAssertEqual(result.error as? GenerationError, .badResponse)
    }

    func testAStreamThatEndsBeforeItCompletesIsANetworkProblem() async {
        let result = await run([.ok(OpenAIFixtures.stream(ending: nil))])
        XCTAssertEqual(result.error as? GenerationError, .network)
        XCTAssertEqual(result.events.count, 4, "what was read before stays")
        XCTAssertFalse(result.events.contains { if case .finished = $0 { true } else { false } })
    }

    func testTheConnectionDroppingMidStreamKeepsTheCardsAndIsNetwork() async {
        let lines = Array(OpenAIFixtures.stream(ending: nil).prefix(40))
        let result = await run([.stream(status: 200, headers: [:], lines: lines, endsWith: URLError(.networkConnectionLost))])
        XCTAssertEqual(result.error as? GenerationError, .network)
    }

    // MARK: Failures inside the stream

    func testResponseFailedKeepsTheCardsAlreadyParsed() async {
        let first = #"{"deckName":"Cells","cards":[{"front":"A","back":"B","sourcePage":null},"#
        let lines = OpenAIFixtures.lines(OpenAIFixtures.beginning + [
            OpenAIFixtures.textDelta(first),
            #"{"type":"response.failed","sequence_number":9,"response":{"id":"resp_1","status":"failed","error":{"code":"server_error","message":"oops"}}}"#,
        ])
        let result = await run([.ok(lines)])
        XCTAssertEqual(result.error as? GenerationError, .overloaded)
        XCTAssertEqual(result.events, [.deckName("Cells"), .card(GeneratedCard(front: "A", back: "B", sourcePage: nil))])
    }

    func testErrorEventKinds() {
        XCTAssertEqual(OpenAIErrors.streamError(code: "rate_limit_exceeded"), .rateLimited(retryAfter: nil))
        XCTAssertEqual(OpenAIErrors.streamError(code: "insufficient_quota"), .outOfCredit)
        XCTAssertEqual(OpenAIErrors.streamError(code: "server_error"), .overloaded)
        XCTAssertEqual(OpenAIErrors.streamError(code: "invalid_prompt"), .refused)
        XCTAssertEqual(OpenAIErrors.streamError(code: "bio_policy"), .refused)
        XCTAssertEqual(OpenAIErrors.streamError(code: "image_too_large"), .tooLarge)
        XCTAssertEqual(OpenAIErrors.streamError(code: "something_else"), .badResponse)
        XCTAssertEqual(OpenAIErrors.streamError(code: nil), .badResponse)
    }

    func testAnErrorEventStopsTheRun() async {
        let lines = OpenAIFixtures.lines(OpenAIFixtures.beginning + [#"{"type":"error","code":"rate_limit_exceeded","message":"slow","param":null,"sequence_number":3}"#])
        let result = await run([.ok(lines)])
        XCTAssertEqual(result.error as? GenerationError, .rateLimited(retryAfter: nil))
    }

    // MARK: Errors before the stream starts

    func testStatusMapping() async {
        let cases: [(Int, GenerationError)] = [(401, .invalidKey), (403, .modelForbidden), (404, .modelForbidden), (413, .tooLarge), (418, .badResponse)]
        for (status, expected) in cases {
            let result = await run([.status(status, OpenAIFixtures.errorBody(message: "nope"))])
            XCTAssertEqual(result.error as? GenerationError, expected, "\(status)")
            XCTAssertEqual(result.api.requests.count, 1, "\(status) isn't asked again")
            XCTAssertTrue(result.events.isEmpty)
        }
        XCTAssertTrue(GenerationError.modelForbidden.needsModelListRefresh)
        XCTAssertFalse(GenerationError.invalidKey.needsModelListRefresh)
    }

    func testRateLimitUsesRetryAfter() async {
        let body = OpenAIFixtures.errorBody(code: "rate_limit_exceeded", type: "requests", message: "Rate limit reached")
        let result = await run([.status(429, body, headers: ["retry-after": "20"])])
        XCTAssertEqual(result.error as? GenerationError, .rateLimited(retryAfter: 20))
        let without = await run([.status(429, body)])
        XCTAssertEqual(without.error as? GenerationError, .rateLimited(retryAfter: nil))
        XCTAssertEqual(without.api.requests.count, 1)
    }

    func testOutOfCreditIsToldApartFromTooManyRequests() async {
        for body in [
            OpenAIFixtures.errorBody(code: "insufficient_quota", type: "insufficient_quota", message: "You exceeded your current quota"),
            OpenAIFixtures.errorBody(type: "insufficient_quota", message: "quota"),
        ] {
            let result = await run([.status(429, body, headers: ["retry-after": "20"])])
            XCTAssertEqual(result.error as? GenerationError, .outOfCredit)
            XCTAssertEqual(result.api.requests.count, 1)
        }
        XCTAssertTrue(GenerationError.outOfCredit.message.contains("out of credit"))
    }

    func testBusyServiceIsAskedAgainOnceThenSaysOverloaded() async {
        for status in [500, 502, 503] {
            let twice = await run([.status(status), .status(status), .ok(OpenAIFixtures.stream())])
            XCTAssertEqual(twice.error as? GenerationError, .overloaded, "\(status)")
            XCTAssertEqual(twice.api.requests.count, 2, "\(status): one more try, not two")

            let recovers = await run([.status(status), .ok(OpenAIFixtures.stream())])
            XCTAssertNil(recovers.error, "\(status)")
            XCTAssertEqual(recovers.events, OpenAIFixtures.expectedEvents)
            XCTAssertEqual(recovers.api.requests.count, 2)
        }
    }

    func testNetworkFailure() async {
        let result = await run([.failure(URLError(.notConnectedToInternet))])
        XCTAssertEqual(result.error as? GenerationError, .network)
        XCTAssertEqual(result.api.requests.count, 1)
    }

    func testTooMuchFailsBeforeAnythingIsSent() async {
        let result = await run([.ok(OpenAIFixtures.stream())], request: OpenAIFixtures.request(pdfPages: 601))
        XCTAssertEqual(result.error as? GenerationError, .tooLarge)
        XCTAssertTrue(result.api.requests.isEmpty)
    }

    // MARK: A model that can't do this

    func testA400AboutTheModelOrAParameterIsMarkedUnsupportedForTheSession() async {
        let bodies = [
            OpenAIFixtures.errorBody(code: "unsupported_parameter", param: "text.format", message: "Unsupported parameter: 'text.format' is not supported with this model."),
            OpenAIFixtures.errorBody(message: "This model does not support file inputs."),
            OpenAIFixtures.errorBody(code: "model_not_found_for_request", param: "model", message: "The model `gpt-6-astra` does not exist."),
            OpenAIFixtures.errorBody(param: "input[0].content[1]", message: "Invalid content"),
        ]
        for body in bodies {
            let unsupported = UnsupportedModels()
            let result = await run([.status(400, body), .ok(OpenAIFixtures.stream())], unsupported: unsupported)
            XCTAssertEqual(result.error as? GenerationError, .modelCantMakeCards, "\(body)")
            XCTAssertEqual(result.api.requests.count, 1, "not asked again")
            XCTAssertTrue(unsupported.contains("gpt-6-astra", provider: .openAI))
            XCTAssertFalse(unsupported.contains("gpt-6-astra", provider: .anthropic))
            XCTAssertFalse(unsupported.contains("gpt-6.1-sol", provider: .openAI))
        }
        XCTAssertEqual(GenerationError.modelCantMakeCards.message, "This model can't make cards from these files. Pick another model in Settings → AI.")
    }

    func testOtherA400sAreNotHeldAgainstTheModel() async {
        let unsupported = UnsupportedModels()
        let tooLong = await run([.status(400, OpenAIFixtures.errorBody(code: "context_length_exceeded", message: "Your input exceeds the context window of this model."))], unsupported: unsupported)
        XCTAssertEqual(tooLong.error as? GenerationError, .tooLarge, "mentioning the model isn't enough")
        let plain = await run([.status(400, OpenAIFixtures.errorBody(message: "Bad request"))], unsupported: unsupported)
        XCTAssertEqual(plain.error as? GenerationError, .badResponse)
        XCTAssertFalse(unsupported.contains("gpt-6-astra", provider: .openAI))
    }

    func testTheRegistryCanBeCleared() {
        let registry = UnsupportedModels()
        registry.mark("a", provider: .openAI)
        XCTAssertTrue(registry.contains("a", provider: .openAI))
        registry.reset()
        XCTAssertFalse(registry.contains("a", provider: .openAI))
    }

    func testStoppingTheRunStopsTheRequest() async {
        let hang = AsyncThrowingStream<String, Error> { _ in }
        let sent = expectation(description: "request sent")
        let transport: StreamingTransport = { _ in
            sent.fulfill()
            return StreamingHTTPResponse(status: 200, headers: [:], lines: hang)
        }
        let generator = OpenAICardGenerator(apiKey: "k", model: OpenAIFixtures.astra, transport: transport, unsupported: UnsupportedModels())
        let task = Task { await collect(generator.generate(OpenAIFixtures.request())) }
        await fulfillment(of: [sent], timeout: 5)
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.events.isEmpty)
    }
}

// MARK: - Cost

final class OpenAICostTests: XCTestCase {
    private func generator(_ id: String = "gpt-6-astra") -> OpenAICardGenerator {
        OpenAICardGenerator(
            apiKey: "k", model: AIModel(provider: .openAI, id: id, displayName: id, created: nil),
            transport: { _ in XCTFail("nothing is sent to estimate"); throw URLError(.badURL) }
        )
    }

    private func characters(_ request: GenerationRequest) -> Int {
        GenerationPrompt.system.count + GenerationPrompt.parts(for: request).reduce(0) { total, part in
            if case .text(let text) = part { total + text.count } else { total }
        }
    }

    func testRangeFromPagesAndTextLength() async throws {
        let request = OpenAIFixtures.request(pdfPages: 10, cards: 20)
        let estimate = try await generator().estimateCost(for: request)
        let text = characters(request)
        XCTAssertEqual(estimate?.inputTokens, 10 * 800 + Int((Double(text) / 5).rounded(.up)))
        XCTAssertEqual(estimate?.highInputTokens, 10 * 2500 + Int((Double(text) / 3).rounded(.up)))
        // gpt-6-astra is $10 in and $50 out per million; 20 cards is 900 to 1800 tokens out.
        let low = try XCTUnwrap(estimate).low, high = try XCTUnwrap(estimate).high
        XCTAssertEqual(low, Double(estimate!.inputTokens) / 1e6 * 10 + 900.0 / 1e6 * 50, accuracy: 1e-9)
        XCTAssertEqual(high, Double(estimate!.highInputTokens) / 1e6 * 10 + 1800.0 / 1e6 * 50, accuracy: 1e-9)
        XCTAssertLessThan(low, high)
    }

    func testMorePagesAndPicturesCostMore() async throws {
        let small = try await generator().estimateCost(for: OpenAIFixtures.request(pdfPages: 2))
        let more = try await generator().estimateCost(for: OpenAIFixtures.request(pdfPages: 12))
        XCTAssertEqual((more?.inputTokens ?? 0) - (small?.inputTokens ?? 0), 10 * 800)
        XCTAssertEqual((more?.highInputTokens ?? 0) - (small?.highInputTokens ?? 0), 10 * 2500)
        let withPicture = try await generator().estimateCost(for: OpenAIFixtures.request(images: true, pdfPages: 2))
        XCTAssertGreaterThan(withPicture?.inputTokens ?? 0, small?.inputTokens ?? 0)
    }

    func testLineSaysAboutAndWhenPricesWereUpdated() async throws {
        let estimate = try await generator().estimateCost(for: OpenAIFixtures.request(pdfPages: 10))
        let line = try XCTUnwrap(estimate).line(locale: Locale(identifier: "en_US"))
        XCTAssertTrue(line.hasPrefix("about $"), line)
        XCTAssertTrue(line.contains("estimate · prices updated"), line)
    }

    func testNoEstimateWhenThePriceIsNotKnown() async throws {
        let estimate = try await generator("gpt-mystery").estimateCost(for: OpenAIFixtures.request())
        XCTAssertNil(estimate)
    }

    /// Anthropic's exact count still gives one number for the input.
    func testAnExactInputCountHasNoSpread() {
        let estimate = CostEstimate(inputTokens: 10_000, cardCount: 20, price: ModelPrice(inputPerMillion: 4, outputPerMillion: 20))
        XCTAssertEqual(estimate.highInputTokens, 10_000)
    }
}

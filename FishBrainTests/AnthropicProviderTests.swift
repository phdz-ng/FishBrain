import XCTest

/// Making cards with Claude (FLAS-47): the request for each kind of model, the streamed answer, and every
/// way a call can fail. Nothing here goes online: answers are stubbed.

// MARK: - Fixtures

enum AnthropicFixtures {
    static func model(
        _ id: String, images: Bool? = true, effort: Bool? = true,
        maxInput: Int? = 1_000_000, maxOutput: Int? = 128_000
    ) -> AIModel {
        AIModel(
            provider: .anthropic, id: id, displayName: id, created: nil, supportsImages: images,
            supportsStructuredOutput: true, supportsEffort: effort, maxInputTokens: maxInput, maxOutputTokens: maxOutput
        )
    }

    static let opus55 = model("claude-opus-5-5")
    /// An older model: no effort setting, a small context window, no fallbacks.
    static let older = model("claude-sonnet-4-5", effort: false, maxInput: 200_000, maxOutput: 32_000)
    static let textOnly = model("claude-text-only", images: false, effort: false)

    static let pdfBytes = Data("pdf-bytes".utf8)

    static func request(
        model id: String = "claude-opus-5-5", images: Bool = false, pdfPages: Int = 2, cards: Int = 20
    ) -> GenerationRequest {
        var sources: [GenerationSource] = [
            .pdf(PDFSource(data: pdfBytes, filename: "Cells.pdf", pageCount: pdfPages)),
            .text(TextSource(text: "Notes", name: nil)),
        ]
        if images { sources.append(.image(ImageSource(data: Data([1, 2, 3]), mediaType: "image/jpeg", filename: "a.jpg"))) }
        return GenerationRequest(sources: sources, cardCount: cards, modelID: id)
    }

    static func quoted(_ text: String) -> String { OrderedJSON.string(text).text }

    static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func bodyText(_ urlRequest: URLRequest) -> String {
        String(decoding: urlRequest.httpBody ?? Data(), as: UTF8.self)
    }

    static func body(_ urlRequest: URLRequest) -> [String: Any] { json(urlRequest.httpBody ?? Data()) }

    // MARK: Recorded stream

    /// One `data:` payload of a delta that carries a piece of the answer.
    static func textDelta(_ text: String, index: Int = 1) -> String {
        #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":\#(quoted(text))}}"#
    }

    static let messageStart = #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":1200,"output_tokens":1}}}"#

    /// What comes before the text: a thinking block (empty text, as by default), and a fallback block.
    static let thinkingBlock = [
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"{\"deckName\":\"not this\"}"}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":2,"content_block":{"type":"fallback","from":"a","to":"b"}}"#,
        #"{"type":"content_block_stop","index":2}"#,
    ]

    static func messageDelta(_ reason: String?, outputTokens: Int = 90) -> String {
        #"{"type":"message_delta","delta":{"stop_reason":\#(reason.map { quoted($0) } ?? "null"),"stop_sequence":null},"usage":{"output_tokens":\#(outputTokens)}}"#
    }

    /// The lines of a whole answer: `event:` and `data:` lines with blank lines between, as on the wire
    /// (the transport drops the blank ones).
    static func stream(
        text: String = GenerationFixtures.deckJSON, chunkSizes: [Int] = [7, 3, 11], stopReason: String? = "end_turn",
        stop: Bool = true, thinking: Bool = true
    ) -> [String] {
        var payloads = [messageStart, #"{"type":"ping"}"#]
        if thinking { payloads += thinkingBlock }
        payloads.append(#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#)
        payloads += GenerationFixtures.chunks(text, sizes: chunkSizes).map { textDelta($0) }
        payloads.append(#"{"type":"content_block_stop","index":1}"#)
        if stopReason != nil { payloads.append(messageDelta(stopReason)) }
        if stop { payloads.append(#"{"type":"message_stop"}"#) }
        return lines(payloads)
    }

    static func lines(_ payloads: [String]) -> [String] {
        payloads.flatMap { payload -> [String] in
            let type = (try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])?["type"] as? String ?? "?"
            return ["event: \(type)", "data: \(payload)", ""]
        }
    }

    static var finishedUsage: GenerationUsage { GenerationUsage(inputTokens: 1200, outputTokens: 90) }

    static var expectedEvents: [GenerationEvent] {
        let deck = GenerationFixtures.expectedDeck
        return [.deckName(deck.deckName)] + deck.cards.map(GenerationEvent.card) + [.finished(finishedUsage)]
    }

    static func errorBody(_ type: String, _ message: String) -> [String] {
        [#"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#]
    }
}

/// Stands in for api.anthropic.com: hands back queued answers and remembers what was asked.
final class FakeStreamingAPI: @unchecked Sendable {
    enum Reply {
        case stream(status: Int, headers: [String: String], lines: [String], endsWith: Error?)
        case failure(Error)

        static func ok(_ lines: [String]) -> Reply { .stream(status: 200, headers: [:], lines: lines, endsWith: nil) }
        static func status(_ status: Int, _ lines: [String] = [], headers: [String: String] = [:]) -> Reply {
            .stream(status: status, headers: headers, lines: lines, endsWith: nil)
        }
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var transport: StreamingTransport {
        { [self] request in
            let reply: Reply = lock.withLock {
                requests.append(request)
                return replies.isEmpty ? .status(500) : replies.removeFirst()
            }
            switch reply {
            case .failure(let error): throw error
            case .stream(let status, let headers, let lines, let endsWith):
                let stream = AsyncThrowingStream<String, Error> { continuation in
                    for line in lines { continuation.yield(line) }
                    continuation.finish(throwing: endsWith)
                }
                return StreamingHTTPResponse(status: status, headers: headers, lines: stream)
            }
        }
    }
}

/// Runs a stream to its end, keeping everything it said before it stopped.
func collect(_ stream: AsyncThrowingStream<GenerationEvent, Error>) async -> (events: [GenerationEvent], error: Error?) {
    var events: [GenerationEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

// MARK: - The request

final class AnthropicRequestTests: XCTestCase {
    private func builder(_ model: AIModel) -> AnthropicRequestBuilder {
        AnthropicRequestBuilder(capabilities: AnthropicCapabilities(model: model))
    }

    /// The exact body for Opus 5.5, member by member, with the schema in the order it was written.
    func testBodyForOpus55() throws {
        let request = AnthropicFixtures.request()
        let body = try builder(AnthropicFixtures.opus55).messagesBody(for: request).text
        let q = AnthropicFixtures.quoted
        let expected = #"{"model":"claude-opus-5-5","max_tokens":64000,"stream":true,"fallbacks":"default","system":\#(q(GenerationPrompt.system)),"output_config":{"effort":"medium","format":{"type":"json_schema","schema":\#(CardSchema.schema.text)}},"messages":[{"role":"user","content":[{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":"\#(AnthropicFixtures.pdfBytes.base64EncodedString())"}},{"type":"text","text":\#(q(GenerationPrompt.textBlock(TextSource(text: "Notes", name: nil))))},{"type":"text","text":\#(q(GenerationPrompt.instructions(for: request)))}]}]}"#
        XCTAssertEqual(body, expected)
    }

    func testSchemaKeepsDeckNameFirst() throws {
        let body = try builder(AnthropicFixtures.opus55).messagesBody(for: AnthropicFixtures.request()).text
        let name = try XCTUnwrap(body.range(of: #""deckName""#)), cards = try XCTUnwrap(body.range(of: #""cards""#))
        XCTAssertLessThan(name.lowerBound, cards.lowerBound)
    }

    /// A model that says it has no effort setting gets none, and no fallbacks since it isn't on the list.
    func testBodyForModelWithoutEffort() throws {
        let request = AnthropicFixtures.request(model: "claude-sonnet-4-5")
        let urlRequest = try builder(AnthropicFixtures.older).messagesRequest(for: request, apiKey: "k")
        let body = AnthropicFixtures.body(urlRequest)
        XCTAssertEqual(body["max_tokens"] as? Int, 32_000, "the smaller of 64000 and what the model can write")
        let config = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertNil(config["effort"])
        XCTAssertNotNil(config["format"])
        XCTAssertNil(body["fallbacks"])
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testEffortIsLowForHaikuAndMediumOtherwise() {
        XCTAssertEqual(AnthropicCapabilities(model: AnthropicFixtures.model("claude-haiku-5-5")).effort, "low")
        XCTAssertEqual(AnthropicCapabilities(model: AnthropicFixtures.model("claude-sonnet-5-5")).effort, "medium")
        XCTAssertNil(AnthropicCapabilities(model: AnthropicFixtures.model("claude-x", effort: nil)).effort, "unknown is treated as not supported")
    }

    func testMaxTokensIsCappedAt64000AndTakesTheModelsOwnWhenSmaller() {
        XCTAssertEqual(AnthropicCapabilities(model: AnthropicFixtures.model("m", maxOutput: 128_000)).maxTokens, 64_000)
        XCTAssertEqual(AnthropicCapabilities(model: AnthropicFixtures.model("m", maxOutput: 8_192)).maxTokens, 8_192)
        XCTAssertEqual(AnthropicCapabilities(model: AnthropicFixtures.model("m", maxOutput: nil)).maxTokens, 64_000)
    }

    /// A model that can't read pictures: the pictures are not sent (and the run says why instead).
    func testModelWithoutImageInputRefusesPicturesAndSendsNothing() throws {
        let withPicture = AnthropicFixtures.request(images: true)
        XCTAssertThrowsError(try builder(AnthropicFixtures.textOnly).messagesBody(for: withPicture)) {
            XCTAssertEqual($0 as? GenerationError, .imagesNotSupported)
        }
        let body = try builder(AnthropicFixtures.textOnly).messagesBody(for: AnthropicFixtures.request()).text
        XCTAssertFalse(body.contains(#""type":"image""#))
    }

    func testPicturesGoInAsImageBlocksAfterDocumentsAndBeforeText() throws {
        let body = AnthropicFixtures.json(try builder(AnthropicFixtures.opus55).messagesBody(for: AnthropicFixtures.request(images: true)).data)
        let message = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first)
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["document", "image", "text", "text"])
        let source = try XCTUnwrap(content[1]["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertFalse((source["data"] as? String ?? "").contains("\n"))
    }

    /// What current models turn down with a 400 must never be in a body.
    func testBodyHasNothingTheCurrentModelsRefuse() throws {
        for model in [AnthropicFixtures.opus55, AnthropicFixtures.older] {
            let text = try builder(model).messagesBody(for: AnthropicFixtures.request(images: true)).text
            for forbidden in ["thinking", "budget_tokens", "temperature", "top_p", "top_k", "citations"] {
                XCTAssertFalse(text.replacingOccurrences(of: GenerationPrompt.system, with: "").contains("\"\(forbidden)\""), forbidden)
            }
            let body = AnthropicFixtures.json(Data(text.utf8))
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.map { $0["role"] as? String }, ["user"], "no assistant message to continue")
        }
    }

    func testHeadersAndTheKeyOnlyInAHeader() throws {
        let key = "sk-ant-secret-1234"
        let request = AnthropicFixtures.request()
        let urlRequest = try builder(AnthropicFixtures.opus55).messagesRequest(for: request, apiKey: key)
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), key)
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertFalse(urlRequest.url!.absoluteString.contains(key))
        XCTAssertFalse(AnthropicFixtures.bodyText(urlRequest).contains(key))
    }

    func testFallbacksOnlyForModelsOnTheList() {
        for id in ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"] {
            XCTAssertTrue(AnthropicCapabilities(model: AnthropicFixtures.model(id)).supportsFallbacks, id)
        }
        for id in ["claude-haiku-5-5", "claude-opus-4-8", "claude-sonnet-4-5"] {
            XCTAssertFalse(AnthropicCapabilities(model: AnthropicFixtures.model(id)).supportsFallbacks, id)
        }
    }

    func testRetryWithoutFallbacksLeavesThemOutOfBodyAndHeader() throws {
        let plain = AnthropicRequestBuilder(capabilities: AnthropicCapabilities(model: AnthropicFixtures.opus55), useFallbacks: false)
        let urlRequest = try plain.messagesRequest(for: AnthropicFixtures.request(), apiKey: "k")
        XCTAssertNil(AnthropicFixtures.body(urlRequest)["fallbacks"])
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testBase64SlashesAreNotEscaped() {
        XCTAssertEqual(OrderedJSON.string("a/b+c==").text, #""a/b+c==""#)
    }

    func testPDFPageLimitFollowsTheContextWindow() throws {
        let hundred = AnthropicFixtures.request(pdfPages: 100), more = AnthropicFixtures.request(pdfPages: 101)
        XCTAssertNoThrow(try builder(AnthropicFixtures.older).messagesBody(for: hundred))
        XCTAssertThrowsError(try builder(AnthropicFixtures.older).messagesBody(for: more)) {
            XCTAssertEqual($0 as? GenerationError, .tooLarge)
        }
        XCTAssertNoThrow(try builder(AnthropicFixtures.opus55).messagesBody(for: more), "a 1M window takes up to 600")
        XCTAssertThrowsError(try builder(AnthropicFixtures.opus55).messagesBody(for: AnthropicFixtures.request(pdfPages: 601)))
    }

    func testCountTokensBodyIsTheSameWithoutMaxTokensStreamAndFallbacks() throws {
        let request = AnthropicFixtures.request()
        let urlRequest = try builder(AnthropicFixtures.opus55).countTokensRequest(for: request, apiKey: "k")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages/count_tokens")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "anthropic-beta"))
        let count = AnthropicFixtures.body(urlRequest)
        let message = AnthropicFixtures.body(try builder(AnthropicFixtures.opus55).messagesRequest(for: request, apiKey: "k"))
        XCTAssertEqual(Set(count.keys), ["model", "system", "output_config", "messages"])
        for key in ["model", "system"] { XCTAssertEqual(count[key] as? String, message[key] as? String) }
        XCTAssertEqual(NSDictionary(dictionary: count["output_config"] as! [String: Any]), NSDictionary(dictionary: message["output_config"] as! [String: Any]))
        XCTAssertEqual((count["messages"] as? NSArray), (message["messages"] as? NSArray))
    }
}

// MARK: - The answer

final class AnthropicStreamTests: XCTestCase {
    private func run(_ replies: [FakeStreamingAPI.Reply], model: AIModel = AnthropicFixtures.opus55, request: GenerationRequest = AnthropicFixtures.request()) async -> (api: FakeStreamingAPI, events: [GenerationEvent], error: Error?) {
        let api = FakeStreamingAPI(replies)
        let generator = AnthropicCardGenerator(apiKey: "sk-ant-test", model: model, transport: api.transport, retryDelay: 0)
        let result = await collect(generator.generate(request))
        return (api, result.events, result.error)
    }

    /// A thinking block and a fallback block around the text, chunks that fall anywhere: the name, the
    /// cards, then the tokens used.
    func testRecordedStreamGivesNameCardsAndUsage() async {
        for sizes in [[7, 3, 11], [1], [500]] {
            let result = await run([.ok(AnthropicFixtures.stream(chunkSizes: sizes))])
            XCTAssertNil(result.error)
            XCTAssertEqual(result.events, AnthropicFixtures.expectedEvents, "chunks \(sizes)")
        }
    }

    func testCardsAreReportedBeforeTheAnswerEnds() {
        let reader = AnthropicStreamReader()
        var seen: [GenerationEvent] = []
        let lines = AnthropicFixtures.stream(stopReason: nil, stop: false)
        for line in lines where line.hasPrefix("data: ") {
            seen += (try? reader.handle(payload: String(line.dropFirst(6)))) ?? []
        }
        XCTAssertEqual(seen.count, 4, "the name and three cards, with no stop reason yet")
        XCTAssertFalse(reader.isStopped)
    }

    func testThinkingTextIsNeverMistakenForTheAnswer() async {
        let result = await run([.ok(AnthropicFixtures.stream(thinking: true))])
        XCTAssertFalse(result.events.contains(.deckName("not this")))
    }

    func testUnknownEventsAreSkipped() async {
        let lines = AnthropicFixtures.lines(["{\"type\":\"something_new\",\"x\":1}", "not json at all"]) + AnthropicFixtures.stream()
        let result = await run([.ok(lines)])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events, AnthropicFixtures.expectedEvents)
    }

    func testTheRequestSentIsTheStreamingOne() async throws {
        let result = await run([.ok(AnthropicFixtures.stream())])
        let sent = try XCTUnwrap(result.api.requests.first)
        XCTAssertEqual(AnthropicFixtures.body(sent)["stream"] as? Bool, true)
        XCTAssertEqual(result.api.requests.count, 1)
    }

    // MARK: Ending

    func testMaxTokensKeepsTheCardsAndSaysTruncated() async {
        let partial = #"{"deckName":"Cells","cards":[{"front":"A","back":"B","sourcePage":1},{"front":"C","ba"#
        let result = await run([.ok(AnthropicFixtures.stream(text: partial, stopReason: "max_tokens"))])
        XCTAssertEqual(result.error as? GenerationError, .truncated)
        XCTAssertEqual(result.events, [
            .deckName("Cells"), .card(GeneratedCard(front: "A", back: "B", sourcePage: 1)),
            .finished(AnthropicFixtures.finishedUsage),
        ])
    }

    func testRefusalSaysRefusedAfterTheTokensUsed() async {
        let result = await run([.ok(AnthropicFixtures.stream(text: "", stopReason: "refusal"))])
        XCTAssertEqual(result.error as? GenerationError, .refused)
        XCTAssertEqual(result.events, [.finished(AnthropicFixtures.finishedUsage)])
    }

    func testAnAnswerThatIsNotADeckIsBadResponse() async {
        let result = await run([.ok(AnthropicFixtures.stream(text: "Sorry, I can't.", stopReason: "end_turn"))])
        XCTAssertEqual(result.error as? GenerationError, .badResponse)
    }

    func testAStreamThatEndsWithoutAStopReasonIsANetworkProblem() async {
        let result = await run([.ok(AnthropicFixtures.stream(stopReason: nil, stop: false))])
        XCTAssertEqual(result.error as? GenerationError, .network)
        XCTAssertEqual(result.events.count, 4, "what was read before stays")
        XCTAssertFalse(result.events.contains { if case .finished = $0 { true } else { false } })
    }

    func testTheConnectionDroppingMidStreamKeepsTheCardsAndIsNetwork() async {
        let lines = Array(AnthropicFixtures.stream(stopReason: nil, stop: false).prefix(40))
        let result = await run([.stream(status: 200, headers: [:], lines: lines, endsWith: URLError(.networkConnectionLost))])
        XCTAssertEqual(result.error as? GenerationError, .network)
    }

    // MARK: Errors

    func testAnErrorEventMidStreamKeepsTheCardsAlreadyParsed() async {
        let first = #"{"deckName":"Cells","cards":[{"front":"A","back":"B","sourcePage":null},"#
        var payloads = [AnthropicFixtures.messageStart, #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#]
        payloads.append(AnthropicFixtures.textDelta(first, index: 0))
        payloads.append(AnthropicFixtures.textDelta(#"{"front":"C","back":"D","sourcePage":null}"#, index: 0))
        payloads.append(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        let result = await run([.ok(AnthropicFixtures.lines(payloads))])
        XCTAssertEqual(result.error as? GenerationError, .overloaded)
        XCTAssertEqual(result.events, [
            .deckName("Cells"), .card(GeneratedCard(front: "A", back: "B", sourcePage: nil)),
            .card(GeneratedCard(front: "C", back: "D", sourcePage: nil)),
        ])
    }

    func testStreamErrorKinds() {
        XCTAssertEqual(AnthropicErrors.error(streamType: "authentication_error"), .invalidKey)
        XCTAssertEqual(AnthropicErrors.error(streamType: "permission_error"), .modelForbidden)
        XCTAssertEqual(AnthropicErrors.error(streamType: "not_found_error"), .modelUnavailable)
        XCTAssertEqual(AnthropicErrors.error(streamType: "request_too_large"), .tooLarge)
        XCTAssertEqual(AnthropicErrors.error(streamType: "rate_limit_error"), .rateLimited(retryAfter: nil))
        XCTAssertEqual(AnthropicErrors.error(streamType: "api_error"), .overloaded)
        XCTAssertEqual(AnthropicErrors.error(streamType: "overloaded_error"), .overloaded)
        XCTAssertEqual(AnthropicErrors.error(streamType: "invalid_request_error"), .badResponse)
        XCTAssertEqual(AnthropicErrors.error(streamType: nil), .badResponse)
    }

    func testStatusMapping() async {
        let cases: [(Int, GenerationError)] = [
            (401, .invalidKey), (403, .modelForbidden), (404, .modelUnavailable), (413, .tooLarge),
            (400, .badResponse), (418, .badResponse),
        ]
        for (status, expected) in cases {
            let result = await run([.status(status, AnthropicFixtures.errorBody("x", "nope"))])
            XCTAssertEqual(result.error as? GenerationError, expected, "\(status)")
            XCTAssertEqual(result.api.requests.count, 1, "\(status) isn't asked again")
            XCTAssertTrue(result.events.isEmpty)
        }
    }

    func testRateLimitUsesRetryAfter() async {
        let result = await run([.status(429, AnthropicFixtures.errorBody("rate_limit_error", "slow down"), headers: ["retry-after": "30"])])
        XCTAssertEqual(result.error as? GenerationError, .rateLimited(retryAfter: 30))
        XCTAssertEqual(result.api.requests.count, 1)
        let without = await run([.status(429)])
        XCTAssertEqual(without.error as? GenerationError, .rateLimited(retryAfter: nil))
    }

    func testAPromptThatIsTooLongIsTooLarge() async {
        let result = await run([.status(400, AnthropicFixtures.errorBody("invalid_request_error", "prompt is too long: 1200000 tokens > 1000000 maximum"))])
        XCTAssertEqual(result.error as? GenerationError, .tooLarge)
    }

    func testBusyServiceIsAskedAgainOnceThenSaysOverloaded() async {
        for status in [500, 503, 529] {
            let twice = await run([.status(status), .status(status), .ok(AnthropicFixtures.stream())])
            XCTAssertEqual(twice.error as? GenerationError, .overloaded, "\(status)")
            XCTAssertEqual(twice.api.requests.count, 2, "\(status): one more try, not two")

            let recovers = await run([.status(status), .ok(AnthropicFixtures.stream())])
            XCTAssertNil(recovers.error, "\(status)")
            XCTAssertEqual(recovers.events, AnthropicFixtures.expectedEvents)
            XCTAssertEqual(recovers.api.requests.count, 2)
        }
    }

    func testNetworkFailure() async {
        let result = await run([.failure(URLError(.notConnectedToInternet))])
        XCTAssertEqual(result.error as? GenerationError, .network)
        XCTAssertEqual(result.api.requests.count, 1)
    }

    func testPicturesForATextOnlyModelFailBeforeAnythingIsSent() async {
        let result = await run([.ok(AnthropicFixtures.stream())], model: AnthropicFixtures.textOnly, request: AnthropicFixtures.request(model: "claude-text-only", images: true))
        XCTAssertEqual(result.error as? GenerationError, .imagesNotSupported)
        XCTAssertTrue(result.api.requests.isEmpty)
    }

    // MARK: Fallbacks

    func testA400AboutFallbacksIsAskedAgainOnceWithoutThem() async throws {
        let rejection = AnthropicFixtures.errorBody("invalid_request_error", "fallbacks: Extra inputs are not permitted")
        let result = await run([.status(400, rejection), .ok(AnthropicFixtures.stream())])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events, AnthropicFixtures.expectedEvents)
        XCTAssertEqual(result.api.requests.count, 2)
        let (first, second) = (result.api.requests[0], result.api.requests[1])
        XCTAssertEqual(AnthropicFixtures.body(first)["fallbacks"] as? String, "default")
        XCTAssertNotNil(first.value(forHTTPHeaderField: "anthropic-beta"))
        XCTAssertNil(AnthropicFixtures.body(second)["fallbacks"])
        XCTAssertNil(second.value(forHTTPHeaderField: "anthropic-beta"))
        XCTAssertEqual(AnthropicFixtures.body(first)["model"] as? String, AnthropicFixtures.body(second)["model"] as? String)
    }

    func testFallbacksAreOnlyDroppedOnce() async {
        let rejection = AnthropicFixtures.errorBody("invalid_request_error", "fallbacks: nope")
        let result = await run([.status(400, rejection), .status(400, rejection), .ok(AnthropicFixtures.stream())])
        XCTAssertEqual(result.error as? GenerationError, .badResponse)
        XCTAssertEqual(result.api.requests.count, 2)
    }

    func testOtherA400sAreNotRetried() async {
        let result = await run([.status(400, AnthropicFixtures.errorBody("invalid_request_error", "max_tokens: too many")), .ok(AnthropicFixtures.stream())])
        XCTAssertEqual(result.error as? GenerationError, .badResponse)
        XCTAssertEqual(result.api.requests.count, 1)
    }

    func testAModelWithoutFallbacksIsNotRetriedOnAFallbacksMessage() async {
        let rejection = AnthropicFixtures.errorBody("invalid_request_error", "fallbacks: nope")
        let result = await run([.status(400, rejection), .ok(AnthropicFixtures.stream())], model: AnthropicFixtures.older, request: AnthropicFixtures.request(model: "claude-sonnet-4-5"))
        XCTAssertEqual(result.error as? GenerationError, .badResponse)
        XCTAssertEqual(result.api.requests.count, 1)
    }

    // MARK: Stopping

    func testStoppingTheRunStopsTheRequest() async {
        let hang = AsyncThrowingStream<String, Error> { _ in }
        let sent = expectation(description: "request sent")
        let transport: StreamingTransport = { _ in
            sent.fulfill()
            return StreamingHTTPResponse(status: 200, headers: [:], lines: hang)
        }
        let generator = AnthropicCardGenerator(apiKey: "k", model: AnthropicFixtures.opus55, transport: transport)
        let task = Task { await collect(generator.generate(AnthropicFixtures.request())) }
        await fulfillment(of: [sent], timeout: 5)
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.events.isEmpty)
    }
}

// MARK: - Cost

final class AnthropicCostTests: XCTestCase {
    private func generator(_ model: AIModel = AnthropicFixtures.opus55, replies: [FakeAPI.Reply]) -> (AnthropicCardGenerator, FakeAPI) {
        let api = FakeAPI(replies)
        return (AnthropicCardGenerator(apiKey: "sk-ant-test", model: model, countTransport: api.transport), api)
    }

    func testEstimateAsksToCountTokensAndPricesTheRange() async throws {
        let (generator, api) = generator(replies: [.json(200, #"{"input_tokens":10000}"#)])
        let estimate = try await generator.estimateCost(for: AnthropicFixtures.request(cards: 20))
        // 20 cards at about 60 tokens: 1200, in a range of 900 to 1800. Opus 5.5 is $4 in and $20 out per million.
        XCTAssertEqual(estimate?.inputTokens, 10_000)
        XCTAssertEqual(estimate?.lowOutputTokens, 900)
        XCTAssertEqual(estimate?.highOutputTokens, 1800)
        XCTAssertEqual(try XCTUnwrap(estimate).low, 0.058, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(estimate).high, 0.076, accuracy: 1e-9)
        XCTAssertEqual(api.requests.count, 1)
        XCTAssertEqual(api.requests.first?.url?.absoluteString, "https://api.anthropic.com/v1/messages/count_tokens")
        let body = AnthropicFixtures.body(try XCTUnwrap(api.requests.first))
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["stream"])
    }

    func testEstimateLineSaysItIsAnEstimateWithTheDate() {
        let estimate = CostEstimate(inputTokens: 10_000, cardCount: 20, price: ModelPrice(inputPerMillion: 4, outputPerMillion: 20))
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(estimate.line(locale: locale), "about $0.06–$0.08 \(AIPricing.estimateNote(locale: locale))")
        XCTAssertTrue(estimate.line(locale: locale).contains("estimate · prices updated"))
    }

    func testRangeLineWords() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(AIPricing.costRangeLine(0.001, 0.004, locale: locale), AIPricing.costLine(0.004, locale: locale))
        XCTAssertTrue(AIPricing.costRangeLine(0.001, 0.004, locale: locale).hasPrefix("less than $0.01"))
        XCTAssertTrue(AIPricing.costRangeLine(0.101, 0.103, locale: locale).hasPrefix("about $0.10 "), "the same cent is said once")
    }

    func testNoEstimateAndNothingSentWhenThePriceIsNotKnown() async throws {
        let (generator, api) = generator(AnthropicFixtures.model("claude-mystery-1"), replies: [.json(200, #"{"input_tokens":5}"#)])
        let estimate = try await generator.estimateCost(for: AnthropicFixtures.request(model: "claude-mystery-1"))
        XCTAssertNil(estimate)
        XCTAssertTrue(api.requests.isEmpty)
    }

    func testEstimateErrorsAreGenerationErrors() async {
        for (status, expected) in [(401, GenerationError.invalidKey), (404, .modelUnavailable), (429, .rateLimited(retryAfter: nil)), (529, .overloaded)] {
            let (generator, _) = generator(replies: [.json(status, "{}")])
            do {
                _ = try await generator.estimateCost(for: AnthropicFixtures.request())
                XCTFail("\(status) should throw")
            } catch {
                XCTAssertEqual(error as? GenerationError, expected, "\(status)")
            }
        }
        let (broken, _) = generator(replies: [.json(200, "[]")])
        do {
            _ = try await broken.estimateCost(for: AnthropicFixtures.request())
            XCTFail("a count that isn't there should throw")
        } catch {
            XCTAssertEqual(error as? GenerationError, .badResponse)
        }
        let (offline, _) = generator(replies: [.failure(URLError(.notConnectedToInternet))])
        do {
            _ = try await offline.estimateCost(for: AnthropicFixtures.request())
            XCTFail("offline should throw")
        } catch {
            XCTAssertEqual(error as? GenerationError, .network)
        }
    }
}

// MARK: - The real transport

/// Answers every request from a closure, so `SystemStreamingTransport` can be tried without a network.
final class StubURLProtocol: URLProtocol {
    static var answer: (status: Int, headers: [String: String], body: String)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer = Self.answer ?? (500, [:], "")
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In two pieces, the second in the middle of a line, as a real connection might.
        let bytes = Array(answer.body.utf8), middle = bytes.count / 2
        client?.urlProtocol(self, didLoad: Data(bytes[..<middle]))
        client?.urlProtocol(self, didLoad: Data(bytes[middle...]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SystemStreamingTransportTests: XCTestCase {
    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        StubURLProtocol.answer = nil
        super.tearDown()
    }

    func testStatusLowercasedHeadersAndLines() async throws {
        StubURLProtocol.answer = (429, ["Retry-After": "12", "Content-Type": "text/event-stream"], "event: a\ndata: {\"type\":\"ping\"}\n\ndata: second\n")
        let response = try await SystemStreamingTransport.transport(using: session)(URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!))
        XCTAssertEqual(response.status, 429)
        XCTAssertEqual(response.headers["retry-after"], "12")
        var lines: [String] = []
        for try await line in response.lines { lines.append(line) }
        XCTAssertEqual(lines, ["event: a", #"data: {"type":"ping"}"#, "data: second"])
    }

    func testAWholeRunThroughTheRealTransport() async {
        StubURLProtocol.answer = (200, ["content-type": "text/event-stream"], AnthropicFixtures.stream().joined(separator: "\n") + "\n")
        let generator = AnthropicCardGenerator(apiKey: "k", model: AnthropicFixtures.opus55, transport: SystemStreamingTransport.transport(using: session))
        let result = await collect(generator.generate(AnthropicFixtures.request()))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events, AnthropicFixtures.expectedEvents)
    }
}

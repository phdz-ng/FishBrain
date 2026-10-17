import Foundation

/// Reads the server-sent events of a streamed Responses answer and turns them into `GenerationEvent`s.
/// Only the `data:` lines matter (each carries its own `type`). Pure and one event at a time, so a
/// recorded stream can be replayed in a test.
///
/// - `response.output_text.delta` text goes to `DeckStreamReader`, which reports the name and each card as
///   they finish.
/// - A refusal comes as `response.refusal.delta` (or as `refusal` content in the finished response) instead of
///   text.
/// - `response.failed` and `error` stop the run with the error they name; cards already sent stay.
/// - Events this doesn't know are skipped: new kinds may be added to the stream.
final class OpenAIStreamReader {
    struct Ending {
        /// What to send after the last event of the stream.
        var events: [GenerationEvent]
        /// What to throw after those. Cards already sent stay with the person.
        var error: GenerationError?
    }

    private struct Payload: Decodable {
        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
        }
        struct Incomplete: Decodable { var reason: String? }
        struct Failure: Decodable {
            var code: String?
            var message: String?
        }
        struct Content: Decodable { var type: String? }
        struct Item: Decodable { var content: [Content]? }
        struct Response: Decodable {
            var status: String?
            var usage: Usage?
            var incompleteDetails: Incomplete?
            var error: Failure?
            var output: [Item]?
        }

        var type: String
        var delta: String?
        var response: Response?
        // The `error` event carries these at the top level.
        var code: String?
        var message: String?
    }

    private enum Outcome {
        case completed
        case incomplete(reason: String?)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private let deck = DeckStreamReader()
    private var outcome: Outcome?
    private var refusalSeen = false
    private var inputTokens: Int?
    private var outputTokens: Int?

    /// The response is over (`completed` or `incomplete`): nothing more is expected.
    var isStopped: Bool { outcome != nil }

    /// Takes one `data:` payload (the JSON after `data: `). Throws when the stream says it failed.
    func handle(payload text: String) throws -> [GenerationEvent] {
        guard let payload = try? Self.decoder.decode(Payload.self, from: Data(text.utf8)) else { return [] }
        switch payload.type {
        case "response.output_text.delta":
            guard let delta = payload.delta, !delta.isEmpty else { return [] }
            return deck.feed(delta).map(Self.event)
        case "response.refusal.delta":
            refusalSeen = true
        case "response.completed":
            record(payload.response)
            outcome = .completed
        case "response.incomplete":
            record(payload.response)
            outcome = .incomplete(reason: payload.response?.incompleteDetails?.reason)
        case "response.failed":
            throw OpenAIErrors.streamError(code: payload.response?.error?.code)
        case "error":
            throw OpenAIErrors.streamError(code: payload.code)
        default:
            break // response.created, in_progress, output_item.*, and anything new
        }
        return []
    }

    private func record(_ response: Payload.Response?) {
        guard let response else { return }
        inputTokens = response.usage?.inputTokens ?? inputTokens
        outputTokens = response.usage?.outputTokens ?? outputTokens
        if response.output?.contains(where: { $0.content?.contains { $0.type == "refusal" } == true }) == true { refusalSeen = true }
    }

    private static func event(_ parsed: StreamingDeckParser.Event) -> GenerationEvent {
        switch parsed {
        case .deckName(let name): .deckName(name)
        case .card(let card): .card(card)
        }
    }

    var usage: GenerationUsage? {
        guard inputTokens != nil || outputTokens != nil else { return nil }
        return GenerationUsage(inputTokens: inputTokens ?? 0, outputTokens: outputTokens ?? 0)
    }

    /// The stream has ended. When the model did answer, `.finished` (with the tokens it used, which are
    /// billed all the same) comes first and then, if the answer can't be used as it is, the reason:
    ///
    /// - completed: a refusal is `.refused`; otherwise the whole text is read once more with a real JSON
    ///   decoder, which has the last word (anything streaming missed is sent; not a deck is `.badResponse`).
    /// - incomplete: `max_output_tokens` is `.truncated`, `content_filter` is `.refused`, anything else
    ///   `.badResponse`. The cards finished so far were already sent.
    /// - neither (the connection ended early): `.network`, without `.finished`.
    func finish() -> Ending {
        switch outcome {
        case .completed:
            if refusalSeen { return Ending(events: [.finished(usage)], error: .refused) }
            let result = deck.finish()
            if let error = result.error { return Ending(events: [.finished(usage)], error: error) }
            return Ending(events: result.lateEvents.map(Self.event) + [.finished(usage)], error: nil)
        case .incomplete(let reason):
            let error: GenerationError = refusalSeen || reason == "content_filter" ? .refused : (reason == "max_output_tokens" ? .truncated : .badResponse)
            return Ending(events: [.finished(usage)], error: error)
        case nil:
            return Ending(events: [], error: .network)
        }
    }
}

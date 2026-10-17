import Foundation

/// Reads the server-sent events of a streamed Messages answer and turns them into `GenerationEvent`s.
/// Only the `data:` lines matter (each carries its own `type`), so blank lines, `event:` lines and
/// comments are ignored. Pure and one event at a time, so a recorded stream can be replayed in a test.
///
/// - Only `text` content blocks are read. Thinking blocks (which may come first, usually empty) and
///   `fallback` blocks are skipped, and so is any kind of block this doesn't know.
/// - The text goes to `DeckStreamReader`, which reports the name and each card as they finish.
/// - How the answer ended decides what comes last (see `finish()`).
final class AnthropicStreamReader {
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
        struct Message: Decodable { var usage: Usage? }
        struct Block: Decodable {
            var type: String?
            var text: String?
        }
        struct Delta: Decodable {
            var type: String?
            var text: String?
            var stopReason: String?
        }
        struct ErrorBody: Decodable { var type: String? }

        var type: String
        var index: Int?
        var message: Message?
        var contentBlock: Block?
        var delta: Delta?
        var usage: Usage?
        var error: ErrorBody?
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private let deck = DeckStreamReader()
    private var textBlocks: Set<Int> = []
    private var inputTokens: Int?
    private var outputTokens: Int?
    private(set) var stopReason: String?
    /// `message_stop` came: nothing more is expected.
    private(set) var isStopped = false

    /// Takes one `data:` payload (the JSON after `data: `). Throws when the stream says it failed.
    func handle(payload text: String) throws -> [GenerationEvent] {
        // An event this doesn't understand is skipped: new kinds of event may be added to the stream.
        guard let payload = try? Self.decoder.decode(Payload.self, from: Data(text.utf8)) else { return [] }
        switch payload.type {
        case "message_start":
            if let usage = payload.message?.usage { record(usage) }
        case "content_block_start":
            guard let index = payload.index, payload.contentBlock?.type == "text" else { return [] }
            textBlocks.insert(index)
            return feed(payload.contentBlock?.text)
        case "content_block_delta":
            guard let index = payload.index, textBlocks.contains(index), payload.delta?.type == "text_delta" else { return [] }
            return feed(payload.delta?.text)
        case "message_delta":
            if let reason = payload.delta?.stopReason { stopReason = reason }
            if let usage = payload.usage { record(usage) }
        case "message_stop":
            isStopped = true
        case "error":
            throw AnthropicErrors.error(streamType: payload.error?.type)
        default:
            break // ping, content_block_stop, and anything new
        }
        return []
    }

    private func record(_ usage: Payload.Usage) {
        inputTokens = usage.inputTokens ?? inputTokens
        outputTokens = usage.outputTokens ?? outputTokens
    }

    private func feed(_ text: String?) -> [GenerationEvent] {
        guard let text, !text.isEmpty else { return [] }
        return deck.feed(text).map(Self.event)
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
    /// - `end_turn`: the whole text is read once more with a real JSON decoder, which has the last word.
    ///   Anything it finds that streaming missed is sent; if it isn't a deck, `.badResponse`.
    /// - `max_tokens`: `.truncated`. The cards finished so far were already sent.
    /// - `refusal`: `.refused`.
    /// - No stop reason (the connection ended early): `.network`, without `.finished`.
    func finish() -> Ending {
        switch stopReason {
        case "end_turn", "stop_sequence":
            let outcome = deck.finish()
            if let error = outcome.error { return Ending(events: [.finished(usage)], error: error) }
            return Ending(events: outcome.lateEvents.map(Self.event) + [.finished(usage)], error: nil)
        case "max_tokens":
            return Ending(events: [.finished(usage)], error: .truncated)
        case "refusal":
            return Ending(events: [.finished(usage)], error: .refused)
        case nil:
            return Ending(events: [], error: .network)
        default:
            return Ending(events: [.finished(usage)], error: .badResponse)
        }
    }
}

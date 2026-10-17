import Foundation

/// Reads the deck as it is written. Both providers stream the JSON a few characters at a time; this
/// reads it as it arrives and says so as soon as the deck's name is complete, and again as each card is,
/// so the cards can appear one by one. The chunks can end anywhere: inside a word, inside an escape such
/// as `\"` or `é`, or inside a number.
///
/// It only watches for the parts it needs. The finished text is read again, once, by a real JSON decoder
/// (`DeckStreamReader`), which has the last word.
struct StreamingDeckParser {
    enum Event: Equatable, Sendable {
        case deckName(String)
        case card(GeneratedCard)
    }

    // MARK: Reading characters into tokens

    private enum Token {
        case beginObject, endObject, beginArray, endArray, comma, colon
        case string(String)
        case number(String)
        case null
        case other // true, false
    }

    private enum Escape {
        case none
        case backslash
        case unicode(String)
    }

    private enum Lexing {
        case idle
        case string(value: String, escape: Escape, highSurrogate: UInt16?)
        case number(String)
        case literal(String)
    }

    private var lexing = Lexing.idle

    // MARK: Following the structure

    private struct Frame {
        var isObject: Bool
        /// The key whose value is being read, in an object.
        var key: String?
        /// Whether the next string in this object is a key.
        var awaitingKey = true
    }

    private struct CardInProgress {
        var front: String?
        var back: String?
        var sourcePage: Int?
    }

    private var stack: [Frame] = []
    private var card: CardInProgress?

    /// The text wasn't JSON (or not shaped as expected). Nothing more is reported.
    private(set) var hasFailed = false
    /// Cards that were finished but had no front or no back, and so were left out.
    private(set) var skippedCards = 0
    /// The closing brace of the whole deck has been seen.
    private(set) var isComplete = false

    // MARK: Feeding

    /// Takes the next piece of text and returns what it finished.
    mutating func feed(_ chunk: String) -> [Event] {
        guard !hasFailed else { return [] }
        var events: [Event] = []
        for scalar in chunk.unicodeScalars {
            guard !hasFailed else { break }
            consume(scalar, into: &events)
        }
        return events
    }

    private mutating func consume(_ scalar: Unicode.Scalar, into events: inout [Event]) {
        switch lexing {
        case .idle:
            consumeIdle(scalar, into: &events)

        case .string(var value, let escape, var high):
            switch escape {
            case .none:
                if scalar == "\"" {
                    flush(&value, &high)
                    lexing = .idle
                    handle(.string(value), into: &events)
                } else if scalar == "\\" {
                    lexing = .string(value: value, escape: .backslash, highSurrogate: high)
                } else {
                    flush(&value, &high)
                    value.unicodeScalars.append(scalar)
                    lexing = .string(value: value, escape: .none, highSurrogate: nil)
                }
            case .backslash:
                let plain: Unicode.Scalar?
                switch scalar {
                case "\"": plain = "\""
                case "\\": plain = "\\"
                case "/": plain = "/"
                case "b": plain = "\u{08}"
                case "f": plain = "\u{0C}"
                case "n": plain = "\n"
                case "r": plain = "\r"
                case "t": plain = "\t"
                case "u": plain = nil
                default: hasFailed = true; return
                }
                if scalar == "u" {
                    lexing = .string(value: value, escape: .unicode(""), highSurrogate: high)
                } else if let plain {
                    flush(&value, &high)
                    value.unicodeScalars.append(plain)
                    lexing = .string(value: value, escape: .none, highSurrogate: nil)
                }
            case .unicode(var digits):
                guard scalar.properties.isASCIIHexDigit else { hasFailed = true; return }
                digits.unicodeScalars.append(scalar)
                if digits.count < 4 {
                    lexing = .string(value: value, escape: .unicode(digits), highSurrogate: high)
                    return
                }
                let code = UInt16(digits, radix: 16) ?? 0xFFFD
                switch code {
                case 0xD800...0xDBFF:
                    // The first half of a pair; the second half comes in the next escape.
                    flush(&value, &high)
                    lexing = .string(value: value, escape: .none, highSurrogate: code)
                case 0xDC00...0xDFFF:
                    if let first = high, let pair = Self.combine(high: first, low: code) {
                        value.unicodeScalars.append(pair)
                    } else {
                        flush(&value, &high)
                        value.unicodeScalars.append("\u{FFFD}")
                    }
                    lexing = .string(value: value, escape: .none, highSurrogate: nil)
                default:
                    flush(&value, &high)
                    value.unicodeScalars.append(Unicode.Scalar(UInt32(code)) ?? "\u{FFFD}")
                    lexing = .string(value: value, escape: .none, highSurrogate: nil)
                }
            }

        case .number(var digits):
            if Self.isNumberCharacter(scalar) {
                digits.unicodeScalars.append(scalar)
                lexing = .number(digits)
            } else {
                lexing = .idle
                handle(.number(digits), into: &events)
                consumeIdle(scalar, into: &events)
            }

        case .literal(var word):
            word.unicodeScalars.append(scalar)
            if ["true", "false", "null"].contains(word) {
                lexing = .idle
                handle(word == "null" ? .null : .other, into: &events)
            } else if "true".hasPrefix(word) || "false".hasPrefix(word) || "null".hasPrefix(word) {
                lexing = .literal(word)
            } else {
                hasFailed = true
            }
        }
    }

    private mutating func consumeIdle(_ scalar: Unicode.Scalar, into events: inout [Event]) {
        switch scalar {
        case " ", "\n", "\r", "\t": break
        case "{": handle(.beginObject, into: &events)
        case "}": handle(.endObject, into: &events)
        case "[": handle(.beginArray, into: &events)
        case "]": handle(.endArray, into: &events)
        case ",": handle(.comma, into: &events)
        case ":": handle(.colon, into: &events)
        case "\"": lexing = .string(value: "", escape: .none, highSurrogate: nil)
        case "t", "f", "n": lexing = .literal(String(Character(scalar)))
        default:
            if Self.isNumberCharacter(scalar) {
                lexing = .number(String(Character(scalar)))
            } else {
                hasFailed = true
            }
        }
    }

    /// A first half with no second half is a broken character: it becomes the replacement character.
    private func flush(_ value: inout String, _ high: inout UInt16?) {
        if high != nil {
            value.unicodeScalars.append("\u{FFFD}")
            high = nil
        }
    }

    private static func combine(high: UInt16, low: UInt16) -> Unicode.Scalar? {
        Unicode.Scalar(0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(low) - 0xDC00))
    }

    private static func isNumberCharacter(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar) || scalar == "-" || scalar == "+" || scalar == "." || scalar == "e" || scalar == "E"
    }

    // MARK: Structure

    /// Directly inside the deck's `cards` array: the card objects.
    private var isInsideCardsArray: Bool {
        stack.count == 2 && stack[0].isObject && !stack[1].isObject && stack[0].key == "cards"
    }

    private mutating func handle(_ token: Token, into events: inout [Event]) {
        switch token {
        case .colon:
            break

        case .comma:
            if !stack.isEmpty, stack[stack.count - 1].isObject { stack[stack.count - 1].awaitingKey = true }

        case .beginObject:
            if isInsideCardsArray { card = CardInProgress() }
            stack.append(Frame(isObject: true))

        case .beginArray:
            stack.append(Frame(isObject: false))

        case .endObject:
            guard let closed = stack.popLast(), closed.isObject else { hasFailed = true; return }
            if isInsideCardsArray, let finished = card {
                card = nil
                if let front = finished.front?.trimmingCharacters(in: .whitespacesAndNewlines), !front.isEmpty,
                   let back = finished.back?.trimmingCharacters(in: .whitespacesAndNewlines), !back.isEmpty {
                    events.append(.card(GeneratedCard(front: front, back: back, sourcePage: finished.sourcePage)))
                } else {
                    skippedCards += 1
                }
            }
            valueFinished()

        case .endArray:
            guard let closed = stack.popLast(), !closed.isObject else { hasFailed = true; return }
            valueFinished()

        case .string(let text):
            if let top = stack.last, top.isObject, top.awaitingKey {
                stack[stack.count - 1].key = text
                stack[stack.count - 1].awaitingKey = false
            } else {
                stringValue(text, into: &events)
                valueFinished()
            }

        case .number(let text):
            if stack.count == 3, isInsideCard, stack[2].key == "sourcePage" {
                card?.sourcePage = Self.page(from: text)
            }
            valueFinished()

        case .null:
            if stack.count == 3, isInsideCard, stack[2].key == "sourcePage" { card?.sourcePage = nil }
            valueFinished()

        case .other:
            valueFinished()
        }
    }

    private var isInsideCard: Bool {
        stack.count == 3 && stack[0].isObject && !stack[1].isObject && stack[2].isObject && stack[0].key == "cards"
    }

    private mutating func stringValue(_ text: String, into events: inout [Event]) {
        if stack.count == 1, stack[0].key == "deckName" {
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { events.append(.deckName(name)) }
        } else if isInsideCard {
            switch stack[2].key {
            case "front": card?.front = text
            case "back": card?.back = text
            default: break
            }
        }
    }

    /// A value is done: its key is used up, and a closing brace of the whole deck ends it.
    private mutating func valueFinished() {
        if stack.isEmpty {
            isComplete = true
        } else if stack[stack.count - 1].isObject {
            stack[stack.count - 1].key = nil
        }
    }

    private static func page(from text: String) -> Int? {
        if let whole = Int(text) { return whole > 0 ? whole : nil }
        if let decimal = Double(text), decimal == decimal.rounded(), decimal > 0 { return Int(decimal) }
        return nil
    }
}

/// Reads a whole streamed answer: it reports the name and each card as they finish, and at the end reads
/// the complete text with a real JSON decoder, which is the final word. If that fails, whatever was
/// already reported stays.
final class DeckStreamReader {
    struct Outcome: Equatable, Sendable {
        /// What the decoder made of the whole text; nil if it wasn't valid JSON.
        var deck: GeneratedDeck?
        /// Anything the final read found that the streaming read hadn't reported (should be nothing).
        var lateEvents: [StreamingDeckParser.Event]
        /// `.badResponse` when the whole text wasn't a deck. A provider that knows the answer was cut
        /// off (it ran out of room) says `.truncated` instead.
        var error: GenerationError?
        /// The closing brace of the deck was seen.
        var isComplete: Bool
        var skippedCards: Int
    }

    private var parser = StreamingDeckParser()
    private(set) var text = ""
    private(set) var reportedName: String?
    private(set) var reportedCards: [GeneratedCard] = []

    /// Takes the next piece of the answer and returns what it finished.
    func feed(_ chunk: String) -> [StreamingDeckParser.Event] {
        text += chunk
        let events = parser.feed(chunk)
        for event in events {
            switch event {
            case .deckName(let name): reportedName = reportedName ?? name
            case .card(let card): reportedCards.append(card)
            }
        }
        return events
    }

    /// The answer has ended.
    func finish() -> Outcome {
        guard let data = text.data(using: .utf8), let deck = try? JSONDecoder().decode(GeneratedDeck.self, from: data) else {
            return Outcome(deck: nil, lateEvents: [], error: .badResponse, isComplete: parser.isComplete, skippedCards: parser.skippedCards)
        }
        let valid = deck.cards.compactMap { card -> GeneratedCard? in
            let front = card.front.trimmingCharacters(in: .whitespacesAndNewlines)
            let back = card.back.trimmingCharacters(in: .whitespacesAndNewlines)
            return front.isEmpty || back.isEmpty ? nil : GeneratedCard(front: front, back: back, sourcePage: card.sourcePage.flatMap { $0 > 0 ? $0 : nil })
        }
        var late: [StreamingDeckParser.Event] = []
        let name = deck.deckName.trimmingCharacters(in: .whitespacesAndNewlines)
        if reportedName == nil, !name.isEmpty { late.append(.deckName(name)) }
        if valid.count > reportedCards.count { late += valid.dropFirst(reportedCards.count).map(StreamingDeckParser.Event.card) }
        return Outcome(
            deck: GeneratedDeck(deckName: name, cards: valid), lateEvents: late, error: nil,
            isComplete: true, skippedCards: deck.cards.count - valid.count
        )
    }
}

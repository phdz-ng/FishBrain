import Foundation

/// JSON written the way it was built, key by key. A normal dictionary loses the order, and the order of a
/// schema's properties is the order the model writes them in: `deckName` has to come first so the deck's
/// name can be shown before the cards.
indirect enum OrderedJSON: Equatable, Sendable {
    struct Member: Equatable, Sendable {
        var key: String
        var value: OrderedJSON
    }

    case object([Member])
    case array([OrderedJSON])
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    static func object(_ members: KeyValuePairs<String, OrderedJSON>) -> OrderedJSON {
        .object(members.map { Member(key: $0.key, value: $0.value) })
    }

    /// Compact JSON text, members in the order given.
    var text: String {
        switch self {
        case .object(let members): "{" + members.map { Self.quote($0.key) + ":" + $0.value.text }.joined(separator: ",") + "}"
        case .array(let items): "[" + items.map(\.text).joined(separator: ",") + "]"
        case .string(let value): Self.quote(value)
        case .int(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        }
    }

    var data: Data { Data(text.utf8) }

    /// The same thing as plain Foundation objects (the order is lost), for checking.
    var foundation: Any {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? NSNull()
    }

    private static func quote(_ string: String) -> String {
        // Slashes stay as they are: base64 is full of them, and `\/` would make every PDF a little bigger on the wire.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(string), let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }
}

/// The shape of what the model must return, shared by both providers. It has to stay inside both of their
/// rules for structured output: every object closed (`additionalProperties: false`), every property
/// required, and none of the length, range or size limits (Anthropic rejects them with an error). The
/// number of cards can't be set here; it is asked for in the prompt and checked afterwards.
enum CardSchema {
    static let deckNameDescription = "A short, specific name for the deck, at most 6 words"
    static let sourcePageDescription = "The 1-based page of the PDF this card is based on, or null"

    static let schema: OrderedJSON = .object([
        "type": .string("object"),
        "properties": .object([
            // First, so the name can be shown before the cards are written.
            "deckName": .object([
                "type": .string("string"),
                "description": .string(deckNameDescription),
            ]),
            "cards": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "front": .object(["type": .string("string")]),
                        "back": .object(["type": .string("string")]),
                        "sourcePage": .object([
                            "type": .array([.string("integer"), .string("null")]),
                            "description": .string(sourcePageDescription),
                        ]),
                    ]),
                    "required": .array([.string("front"), .string("back"), .string("sourcePage")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "required": .array([.string("deckName"), .string("cards")]),
        "additionalProperties": .bool(false),
    ])

    /// What the two providers refuse to accept in a schema.
    static let forbiddenKeywords: Set<String> = [
        "minLength", "maxLength", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "maxItems", "uniqueItems", "minProperties", "maxProperties", "pattern", "format", "$ref", "oneOf", "allOf", "anyOf",
    ]

    /// Anything in `schema` that would be turned down: an object that isn't closed, a property that isn't
    /// required, or a limit the providers don't support. Empty means it is fine.
    static func violations(in schema: Any = CardSchema.schema.foundation, path: String = "$") -> [String] {
        guard let object = schema as? [String: Any] else { return [] }
        var found: [String] = []
        for keyword in forbiddenKeywords where object[keyword] != nil { found.append("\(path): \(keyword) isn't supported") }
        if let minItems = object["minItems"] as? Int, minItems > 1 { found.append("\(path): minItems above 1 isn't supported") }
        let isObject = (object["type"] as? String) == "object"
        if isObject {
            if (object["additionalProperties"] as? Bool) != false { found.append("\(path): additionalProperties must be false") }
            let properties = (object["properties"] as? [String: Any]) ?? [:]
            let required = Set((object["required"] as? [String]) ?? [])
            for name in properties.keys where !required.contains(name) { found.append("\(path): \(name) must be required") }
            for (name, child) in properties { found += violations(in: child, path: "\(path).\(name)") }
        }
        if let items = object["items"] { found += violations(in: items, path: "\(path)[]") }
        return found
    }
}

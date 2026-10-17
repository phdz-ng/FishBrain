import Foundation
import PDFKit

/// A piece of the material: a page of a PDF, or a block of text.
struct MaterialUnit: Equatable, Sendable {
    var text: String
    /// The page of the original PDF it is from.
    var page: Int?
}

/// A part of the material that goes to the model in one go.
struct MaterialChunk: Equatable, Sendable {
    var text: String
    var firstPage: Int?
    var lastPage: Int?
    /// A picture, for the model that can look at one (the text is then empty).
    var image: Data?

    /// How much of the material this is, for sharing the cards out.
    var weight: Int { image == nil ? max(text.count, 1) : OnDeviceChunker.imageWeight }
}

/// Reading the words out of what was added. Only text can be read: a PDF of scanned pages has none.
enum OnDeviceMaterial {
    /// One unit for each page of the PDF that has any text. Pages count from the original's first page.
    static func units(from pdf: PDFSource) -> [MaterialUnit] {
        guard let document = PDFDocument(data: pdf.data) else { return [] }
        return (0..<document.pageCount).compactMap { index in
            let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : MaterialUnit(text: text, page: pdf.firstPage + index)
        }
    }

    /// Pasted or loaded text, a paragraph at a time.
    static func units(from source: TextSource) -> [MaterialUnit] {
        let paragraphs = source.text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var units = paragraphs.map { MaterialUnit(text: $0, page: nil) }
        if let name = source.name, !units.isEmpty { units[0].text = "Text “\(name)”:\n" + units[0].text }
        return units
    }

    /// How many characters of text a PDF has, to tell a scan (none) from a document.
    static func characters(in pdf: PDFSource) -> Int {
        guard let document = PDFDocument(data: pdf.data) else { return 0 }
        return (0..<document.pageCount).reduce(0) { total, index in
            total + (document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0)
        }
    }
}

/// Cutting the material into parts that fit the model's context.
enum OnDeviceChunker {
    /// Text runs about three characters to a token in the worst case (other languages), so that is what is
    /// planned on. A part that is still too long is cut in half and tried again.
    static let charactersPerToken = 3.0
    /// What the instructions, the schema and the request's own words take, whatever the material.
    static let fixedTokens = 750
    /// What a card takes to write, with its front, back and page.
    static let tokensPerCard = 90
    /// A call asks for no more cards than this, so the answer fits next to the material.
    static let maxCardsPerCall = 12
    /// The most calls to make for one run. More material than fits in this many is cut off, and the person is told.
    static let maxCalls = 10
    /// A part is never made smaller than this by splitting.
    static let minCharacters = 800
    /// How much a picture counts for when sharing cards out.
    static let imageWeight = 1500

    /// How many characters of material fit in a call that writes `cards` cards, leaving a tenth in hand.
    static func materialCharacters(contextSize: Int, cards: Int = maxCardsPerCall) -> Int {
        let free = Double(contextSize - fixedTokens - cards * tokensPerCard) * 0.9
        return max(Int(free * charactersPerToken), minCharacters)
    }

    /// The most material one run uses.
    static func capacity(contextSize: Int) -> Int { materialCharacters(contextSize: contextSize) * maxCalls }

    /// How a page or paragraph is shown to the model: pages are marked so a card can say where it came from.
    static func render(_ unit: MaterialUnit) -> String {
        unit.page.map { "[Page \($0)]\n\(unit.text)\n\n" } ?? "\(unit.text)\n\n"
    }

    /// Packs units, in order, into parts of at most `maxCharacters`. A unit longer than that is cut at the
    /// ends of paragraphs, sentences or words.
    static func pack(_ units: [MaterialUnit], maxCharacters: Int) -> [MaterialChunk] {
        var chunks: [MaterialChunk] = []
        var text = ""
        var first: Int?, last: Int?

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(MaterialChunk(text: trimmed, firstPage: first, lastPage: last)) }
            text = ""
            first = nil
            last = nil
        }
        func add(_ unit: MaterialUnit) {
            let piece = render(unit)
            if !text.isEmpty, text.count + piece.count > maxCharacters { flush() }
            text += piece
            if let page = unit.page {
                first = first ?? page
                last = page
            }
        }

        for unit in units {
            if render(unit).count <= maxCharacters {
                add(unit)
            } else {
                for piece in cut(unit.text, into: maxCharacters - 20) { add(MaterialUnit(text: piece, page: unit.page)) }
            }
        }
        flush()
        return chunks
    }

    /// Cuts long text into pieces of at most `limit` characters, at the last paragraph end, sentence end or space.
    static func cut(_ text: String, into limit: Int) -> [String] {
        let limit = max(limit, 100)
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > limit {
            let window = rest.prefix(limit)
            var end = window.endIndex
            for separator in ["\n\n", "\n", ". ", "? ", "! ", " "] {
                if let range = window.range(of: separator, options: .backwards), window.distance(from: window.startIndex, to: range.upperBound) > limit / 3 {
                    end = range.upperBound
                    break
                }
            }
            pieces.append(String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[end...]
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces.filter { !$0.isEmpty }
    }

    /// Shares `count` cards out by weight, at least one each, adding up to `count` (when there are no more parts than cards).
    static func distribute(_ count: Int, weights: [Int]) -> [Int] {
        guard !weights.isEmpty, count > 0 else { return weights.map { _ in 0 } }
        let total = Double(weights.reduce(0, +))
        var shares = weights.map { max(Int((Double($0) / total * Double(count)).rounded(.down)), 1) }
        var assigned = shares.reduce(0, +)
        // Give what is left to the biggest remainders; take back what the minimum of one overspent from the biggest shares.
        let remainders = weights.enumerated().map { (index: $0.offset, rest: Double($0.element) / total * Double(count) - Double(shares[$0.offset])) }
        for item in remainders.sorted(by: { $0.rest > $1.rest }) where assigned < count {
            shares[item.index] += 1
            assigned += 1
        }
        while assigned > count, let biggest = shares.indices.max(by: { shares[$0] < shares[$1] }), shares[biggest] > 1 {
            shares[biggest] -= 1
            assigned -= 1
        }
        return shares
    }

    /// `count` parts picked evenly from `chunks` (the first and last included).
    static func spread<T>(_ items: [T], to count: Int) -> [T] {
        guard count < items.count, count > 0 else { return items }
        guard count > 1 else { return [items[0]] }
        return (0..<count).map { items[Int((Double($0) * Double(items.count - 1) / Double(count - 1)).rounded())] }
    }
}

/// What a run will do with the material: the calls to make, and how much of it they cover.
struct OnDevicePlan: Equatable, Sendable {
    struct Call: Equatable, Sendable {
        var chunk: MaterialChunk?
        var cards: Int
    }

    var calls: [Call]
    var totalCharacters: Int
    var usedCharacters: Int

    /// More material than one run can read: the rest is left out.
    var isCut: Bool { usedCharacters < totalCharacters }
}

enum OnDevicePlanner {
    /// Makes the calls for a request: the material cut into parts that fit, and the cards shared out among them.
    static func plan(units: [MaterialUnit], images: [Data], cardCount: Int, contextSize: Int) -> OnDevicePlan {
        let maxCalls = OnDeviceChunker.maxCalls
        let wanted = max(Int((Double(cardCount) / Double(OnDeviceChunker.maxCardsPerCall)).rounded(.up)), 1)
        let limit = OnDeviceChunker.materialCharacters(contextSize: contextSize)
        let total = units.reduce(0) { $0 + OnDeviceChunker.render($1).count }

        var chunks = OnDeviceChunker.pack(units, maxCharacters: limit)
        // Many cards from little material: more, smaller parts, so each call's answer fits too.
        if chunks.count < wanted, total >= wanted * OnDeviceChunker.minCharacters {
            chunks = OnDeviceChunker.pack(units, maxCharacters: max(total / wanted + 200, OnDeviceChunker.minCharacters))
        }
        let readable = Array(chunks.prefix(maxCalls - min(images.count, maxCalls - 1)))
        let used = readable.reduce(0) { $0 + $1.text.count }
        var parts = readable + images.map { MaterialChunk(text: "", image: $0) }

        if parts.isEmpty {
            // No material at all (only what matters to the person): calls for the topic alone.
            let calls = (0..<min(wanted, maxCalls)).map { _ in 0 }
            let shares = OnDeviceChunker.distribute(cardCount, weights: calls.map { _ in 1 })
            return OnDevicePlan(calls: shares.map { .init(chunk: nil, cards: $0) }, totalCharacters: 0, usedCharacters: 0)
        }
        parts = OnDeviceChunker.spread(parts, to: min(parts.count, cardCount))
        let shares = OnDeviceChunker.distribute(cardCount, weights: parts.map(\.weight))
        let calls = zip(parts, shares).map { OnDevicePlan.Call(chunk: $0, cards: $1) }
        let totalText = chunks.reduce(0) { $0 + $1.text.count }
        return OnDevicePlan(calls: calls, totalCharacters: max(totalText, used), usedCharacters: used)
    }
}

import Foundation

/// Anki stores a field as HTML. This turns it into the plain text a card holds and finds what it points at.
enum AnkiText {
    /// Line-break tags become new lines, other tags are dropped, entities are decoded, and `[sound:…]`
    /// markers are removed.
    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "\\[sound:[^\\]]*\\]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(div|p|li|tr|h[1-6])\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        text = lines.joined(separator: "\n")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            rest = rest[ampersand...]
            if let semicolon = rest.prefix(12).firstIndex(of: ";") {
                let name = String(rest[rest.index(after: rest.startIndex)..<semicolon])
                var replacement: String?
                if let known = namedEntities[name.lowercased()] {
                    replacement = known
                } else if name.hasPrefix("#x") || name.hasPrefix("#X"), let value = UInt32(name.dropFirst(2), radix: 16) {
                    replacement = Unicode.Scalar(value).map { String(Character($0)) }
                } else if name.hasPrefix("#"), let value = UInt32(name.dropFirst()) {
                    replacement = Unicode.Scalar(value).map { String(Character($0)) }
                }
                if let replacement {
                    result += replacement
                    rest = rest[rest.index(after: semicolon)...]
                    continue
                }
            }
            result.append("&")
            rest = rest.dropFirst()
        }
        result += rest
        return result
    }

    /// The `src` of each `<img>`, in order.
    static func pictureNames(in html: String) -> [String] {
        guard let tag = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: .caseInsensitive),
              let source = try? NSRegularExpression(
                pattern: "\\bsrc\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: .caseInsensitive
              )
        else { return [] }
        let whole = NSRange(html.startIndex..., in: html)
        var names: [String] = []
        for match in tag.matches(in: html, range: whole) {
            guard let range = Range(match.range, in: html) else { continue }
            let element = String(html[range])
            let inner = NSRange(element.startIndex..., in: element)
            guard let found = source.firstMatch(in: element, range: inner) else { continue }
            for group in 1...3 where found.range(at: group).location != NSNotFound {
                if let valueRange = Range(found.range(at: group), in: element) {
                    let raw = decodeEntities(String(element[valueRange]))
                    names.append(raw.removingPercentEncoding ?? raw)
                    break
                }
            }
        }
        return names
    }

    static func soundCount(in html: String) -> Int {
        html.components(separatedBy: "[sound:").count - 1
    }

    // MARK: Cloze

    private static let clozePattern = "\\{\\{c(\\d+)::(.*?)(?:::(.*?))?\\}\\}"

    /// The distinct cloze numbers in a text, ascending.
    static func clozeNumbers(in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: clozePattern, options: .dotMatchesLineSeparators) else { return [] }
        let numbers = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Int? in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
        return Array(Set(numbers)).sorted()
    }

    /// The text with every cloze shown as its answer, except number `hiding`, which becomes "[…]".
    static func cloze(_ text: String, hiding number: Int?) -> String {
        guard let regex = try? NSRegularExpression(pattern: clozePattern, options: .dotMatchesLineSeparators) else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let n = Range(match.range(at: 1), in: text),
                  let answer = Range(match.range(at: 2), in: text) else { continue }
            result += text[last..<whole.lowerBound]
            result += Int(text[n]) == number ? "[…]" : String(text[answer])
            last = whole.upperBound
        }
        result += text[last...]
        return result
    }
}

/// Picks the cards out of an Anki package and shapes them as the import's plan.
enum AnkiImport {
    enum Treatment: Equatable, Sendable {
        /// Front and back, as they are.
        case asIs
        /// A note that makes two cards in Anki: one card, front to back.
        case oneCardOfTwo
        /// A blank on the front, the whole sentence on the back; a card for each blank number.
        case clozeBlanks
        case unsupported
    }

    /// One note type in the package and how its notes come in.
    struct TypeRow: Equatable, Sendable, Identifiable {
        var id: Int64
        var name: String
        var noteCount: Int
        var treatment: Treatment

        var detail: String {
            switch treatment {
            case .asIs: "Front and back, as they are. Formatting is dropped, line breaks stay."
            case .oneCardOfTwo: "One card, front to back. The reverse isn't added."
            case .clozeBlanks: "The blank shows as […] on the front; the full sentence is the back."
            case .unsupported: "This type isn't supported. These notes are skipped and listed in the report."
            }
        }
    }

    /// A deck in the package that has notes.
    struct DeckRow: Equatable, Sendable, Identifiable {
        var id: Int64
        /// "Spanish::Grammar::Verbs".
        var fullName: String
        var noteCount: Int
        var names: [String] { fullName.components(separatedBy: "::").compactMap { Subject.cleanName($0) } }
        var depth: Int { max(0, names.count - 1) }
        var name: String { names.last ?? fullName }
    }

    struct Overview: Equatable, Sendable {
        var decks: [DeckRow]
        var types: [TypeRow]
        var noteCount: Int
        var pictureCount: Int
        var soundCount: Int
    }

    /// A picture a card should get once the package's media is stored.
    struct PendingPicture: Equatable, Sendable {
        var cardID: Card.ID
        var side: CardSide
        var mediaName: String
    }

    struct Result: Equatable, Sendable {
        var plan: CSVImportPlan
        var pictures: [PendingPicture]
        var soundCount: Int
    }

    /// What to tell the user when a package can't be opened.
    static func failureMessage(_ error: AnkiPackageError) -> String {
        switch error {
        case .notAPackage:
            "This doesn’t look like an Anki package. In Anki, choose File ▸ Export and pick “Anki Deck Package (*.apkg)”."
        case .tooLarge(let bytes, let limit):
            "The file is \(bytes.formatted(ByteCountFormatStyle(style: .file))), which is over the \(limit.formatted(ByteCountFormatStyle(style: .file))) limit. Export the decks you want from Anki in smaller parts."
        case .unsafe:
            "This package holds files with names that aren’t safe to unpack, so it wasn’t opened."
        case .newerFormat:
            "This package is in a newer Anki format. In Anki, choose File ▸ Export, tick “Support older Anki versions”, and import the new file."
        case .unreadable(let reason):
            "The package couldn’t be read: \(reason)"
        }
    }

    static func treatment(for model: AnkiPackage.Model?) -> Treatment {
        guard let model else { return .unsupported }
        if model.name.lowercased().hasPrefix("image occlusion") { return .unsupported }
        if model.isCloze { return .clozeBlanks }
        guard model.fieldNames.count >= 2 else { return .unsupported }
        if model.templateCount >= 2 || model.name.lowercased().contains("reversed") { return .oneCardOfTwo }
        return .asIs
    }

    // MARK: Overview

    static func overview(of package: AnkiPackage) -> Overview {
        var perDeck: [Int64: Int] = [:]
        var perType: [Int64: Int] = [:]
        var pictures = Set<String>()
        var sounds = 0
        for note in package.notes {
            perDeck[note.deckID, default: 0] += 1
            perType[note.modelID, default: 0] += 1
            for field in note.fields {
                pictures.formUnion(AnkiText.pictureNames(in: field))
                sounds += AnkiText.soundCount(in: field)
            }
        }
        let decks = perDeck.map { id, count in
            DeckRow(id: id, fullName: package.decks[id] ?? "Deck \(id)", noteCount: count)
        }.sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
        let types = perType.map { id, count in
            let model = package.models[id]
            return TypeRow(id: id, name: model?.name ?? "Unknown note type", noteCount: count, treatment: treatment(for: model))
        }.sorted { $0.noteCount > $1.noteCount }
        return Overview(
            decks: decks, types: types, noteCount: package.notes.count,
            pictureCount: pictures.filter { package.hasMedia(named: $0) }.count, soundCount: sounds
        )
    }

    // MARK: Plan

    /// Works out what importing the chosen decks does. `contextSubjectID` is where the new subjects go
    /// (nil: the top level).
    static func plan(
        package: AnkiPackage,
        selectedDeckIDs: Set<Int64>,
        library: Library,
        contextSubjectID: Subject.ID? = nil
    ) -> Result {
        var plan = CSVImportPlan()
        var structure = ImportStructure(library: library, context: contextSubjectID)
        var pictures: [PendingPicture] = []
        var sounds = 0

        // A deck that has decks inside it becomes a subject; its own notes go in a deck of the same name
        // inside it.
        let allPaths = Set(package.decks.values.map { $0.components(separatedBy: "::").compactMap { Subject.cleanName($0) } })
        func hasChildren(_ path: [String]) -> Bool {
            allPaths.contains { $0.count > path.count && Array($0.prefix(path.count)) == path }
        }

        for note in package.notes where selectedDeckIDs.contains(note.deckID) {
            plan.rowCount += 1
            let model = package.models[note.modelID]
            let converted = convert(note, model: model, package: package)
            sounds += converted.sounds
            plan.notices.append(contentsOf: converted.notices)
            if let reason = converted.skipReason {
                plan.skipped.append(.init(rowNumber: 0, reason: .custom(reason)))
                continue
            }

            let path = (package.decks[note.deckID] ?? "Default").components(separatedBy: "::").compactMap { Subject.cleanName($0) }
            let names = path.isEmpty ? ["Default"] : path
            let subjects = hasChildren(names) ? names : Array(names.dropLast())
            let fitted = structure.fit(subjectNames: subjects, deckName: names.last ?? "Default")
            let index = structure.deckIndex(subjectNames: fitted.names, deckName: fitted.deckName)
            for pending in converted.cards {
                let card = Card(front: pending.front, back: pending.back)
                structure.append(card, toDeckAt: index)
                if let name = pending.frontPicture { pictures.append(.init(cardID: card.id, side: .front, mediaName: name)) }
                if let name = pending.backPicture { pictures.append(.init(cardID: card.id, side: .back, mediaName: name)) }
            }
        }
        plan.newSubjects = structure.subjects
        plan.newDecks = structure.decks
        return Result(plan: plan, pictures: pictures, soundCount: sounds)
    }

    private struct PendingCard {
        var front: String
        var back: String
        var frontPicture: String?
        var backPicture: String?
    }

    private struct Conversion {
        var cards: [PendingCard] = []
        var skipReason: String?
        var notices: [String] = []
        var sounds = 0
    }

    private static func convert(_ note: AnkiPackage.Note, model: AnkiPackage.Model?, package: AnkiPackage) -> Conversion {
        var result = Conversion()
        let fields = note.fields
        result.sounds = fields.reduce(0) { $0 + AnkiText.soundCount(in: $1) }
        let label = describe(fields.first ?? "")

        switch treatment(for: model) {
        case .unsupported:
            result.skipReason = "\(model?.name ?? "Unknown type") note · \(label) · type not supported"

        case .asIs, .oneCardOfTwo:
            let front = side(fields[0], package: package, label: label, sideName: "front", into: &result.notices)
            let back = side(fields.count > 1 ? fields[1] : "", package: package, label: label, sideName: "back", into: &result.notices)
            if front.text.isEmpty, front.picture == nil {
                result.skipReason = "\(label) · empty front"
            } else if back.text.isEmpty, back.picture == nil {
                result.skipReason = "\(label) · empty back"
            } else {
                result.cards = [PendingCard(front: front.text, back: back.text, frontPicture: front.picture, backPicture: back.picture)]
            }

        case .clozeBlanks:
            let source = fields[0]
            let numbers = AnkiText.clozeNumbers(in: source)
            let extra = fields.count > 1 ? AnkiText.plain(fields[1]) : ""
            guard !numbers.isEmpty else {
                result.skipReason = "\(label) · cloze note without blanks"
                break
            }
            let full = AnkiText.plain(AnkiText.cloze(source, hiding: nil))
            let back = extra.isEmpty ? full : full + "\n\n" + extra
            let picture = firstPicture(in: source, package: package, label: label, sideName: "text", notices: &result.notices)
            for number in numbers {
                let front = AnkiText.plain(AnkiText.cloze(source, hiding: number))
                result.cards.append(PendingCard(front: front, back: back, frontPicture: picture, backPicture: nil))
            }
        }
        return result
    }

    /// A field as a card side: its text, and the first of its pictures that the package holds.
    private static func side(
        _ html: String, package: AnkiPackage, label: String, sideName: String, into notices: inout [String]
    ) -> (text: String, picture: String?) {
        (AnkiText.plain(html), firstPicture(in: html, package: package, label: label, sideName: sideName, notices: &notices))
    }

    private static func firstPicture(
        in html: String, package: AnkiPackage, label: String, sideName: String, notices: inout [String]
    ) -> String? {
        let names = AnkiText.pictureNames(in: html)
        var kept: String?
        var extras = 0
        for name in names {
            if !package.hasMedia(named: name) {
                notices.append("\(label) · picture “\(name)” is not in the package")
            } else if kept == nil {
                kept = name
            } else {
                extras += 1
            }
        }
        if extras > 0 {
            notices.append("\(label) · \(extras) extra \(extras == 1 ? "picture" : "pictures") on the \(sideName) not kept")
        }
        return kept
    }

    /// "“la cocina”": a note named by its first words.
    private static func describe(_ html: String) -> String {
        let text = AnkiText.plain(html).replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { return "“(no text)”" }
        return "“\(text.count > 32 ? String(text.prefix(31)) + "…" : text)”"
    }

    // MARK: Pictures

    /// Stores the package's pictures and puts them on the cards in `plan`. A picture that can't be read
    /// leaves its card without it and is noted.
    static func attach(_ pending: [PendingPicture], to plan: inout CSVImportPlan, package: AnkiPackage, store: CardImageStore) {
        guard !pending.isEmpty else { return }
        var positions: [Card.ID: (deck: Int, card: Int)] = [:]
        for (deckIndex, deck) in plan.newDecks.enumerated() {
            for (cardIndex, card) in deck.cards.enumerated() { positions[card.id] = (deckIndex, cardIndex) }
        }
        var stored: [String: CardImage?] = [:]
        var failed: Set<String> = []
        for picture in pending {
            guard let position = positions[picture.cardID] else { continue }
            let image: CardImage?
            if let known = stored[picture.mediaName] {
                image = known
            } else {
                image = package.mediaData(named: picture.mediaName).flatMap { try? store.add(data: $0) }
                stored[picture.mediaName] = image
            }
            if let image {
                plan.newDecks[position.deck].cards[position.card].setImage(image, on: picture.side)
            } else if failed.insert(picture.mediaName).inserted {
                plan.notices.append("Picture “\(picture.mediaName)” couldn't be read and was left out")
            }
        }
    }
}

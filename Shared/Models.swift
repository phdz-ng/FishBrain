import Foundation

/// A picture on one side of a card. The files are in the `Images` folder next to `decks.json`: the
/// picture itself (long edge at most 1600 px) and a small copy for the widget and the notch.
struct CardImage: Codable, Hashable, Sendable {
    /// The picture's file, like `3F2A....jpg` (`.png` when it has transparency).
    var fileName: String
    /// What VoiceOver says for it. Blank means the card's text on that side stands in.
    var altText: String?

    /// `3F2A....jpg` -> `3F2A...-thumb.jpg`
    var thumbnailFileName: String {
        let name = fileName as NSString
        return "\(name.deletingPathExtension)-thumb.\(name.pathExtension)"
    }

    /// Both files.
    var fileNames: [String] { [fileName, thumbnailFileName] }
}

enum CardSide: String, Sendable {
    case front, back
}

struct Card: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var front: String
    var back: String
    /// One optional picture per side, shown above that side's text. Files written before pictures
    /// existed have neither.
    var frontImage: CardImage?
    var backImage: CardImage?

    init(id: UUID = UUID(), front: String, back: String, frontImage: CardImage? = nil, backImage: CardImage? = nil) {
        self.id = id
        self.front = front
        self.back = back
        self.frontImage = frontImage
        self.backImage = backImage
    }

    func image(on side: CardSide) -> CardImage? {
        side == .front ? frontImage : backImage
    }

    mutating func setImage(_ image: CardImage?, on side: CardSide) {
        if side == .front { frontImage = image } else { backImage = image }
    }

    /// The image files this card uses.
    var imageFileNames: Set<String> {
        Set([frontImage, backImage].compactMap { $0 }.flatMap(\.fileNames))
    }
}

/// Deck colors from the design system. `.accent` follows the user's accent choice.
/// Unknown values (e.g. written by a newer version) decode as `.accent`.
enum DeckColor: String, Codable, CaseIterable, Sendable {
    case accent, green, purple, orange

    var displayName: String { rawValue.capitalized }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DeckColor(rawValue: raw) ?? .accent
    }
}

struct Deck: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var color: DeckColor
    /// Ordered; the array order is the study order.
    var cards: [Card]
    /// The subject this deck is filed under; nil is a loose deck. Filing a deck never changes its id, so
    /// its review schedule and playback state stay with it.
    var subjectID: UUID?

    init(id: UUID = UUID(), name: String, color: DeckColor = .accent, cards: [Card] = [], subjectID: UUID? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.cards = cards
        self.subjectID = subjectID
    }
}

import Foundation

/// What the drawn notch shows while it rests. A real notch always shows `classic`: the camera is in
/// the middle, so there is only room for the two strips beside it.
enum PillStyle: String, Codable, CaseIterable, Sendable {
    case classic, fish, streak, session

    /// Unknown values (written by a newer version) read as classic.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PillStyle(rawValue: raw) ?? .classic
    }

    var displayName: String {
        switch self {
        case .classic: "Classic"
        case .fish: "Swimming fish"
        case .streak: "Streak & daily goal"
        case .session: "Study session"
        }
    }

    /// One line, shown under the name in the picker, saying what this style shows.
    var summary: String {
        switch self {
        case .classic: "Deck color and card position, like the notch on a Mac with a camera."
        case .fish: "A fish swims across the pill. When it reaches the end, the next card arrives."
        case .streak: "Your streak, this week, and how many cards you've studied today."
        case .session: "A timer for a focused session and how many cards you've reviewed."
        }
    }

    var symbolName: String {
        switch self {
        case .classic: "rectangle.stack"
        case .fish: "fish"
        case .streak: "flame"
        case .session: "timer"
        }
    }

    /// The styles people can pick today. A style joins this list when its own ticket lands.
    static let available: [PillStyle] = [.classic, .fish, .streak, .session]

    var isAvailable: Bool { Self.available.contains(self) }

    /// What to draw for a saved choice: a style that isn't available (a settings file from a newer
    /// version) falls back to classic.
    static func resolved(_ style: PillStyle) -> PillStyle { style.isAvailable ? style : .classic }
}

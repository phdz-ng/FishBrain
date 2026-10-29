import Foundation

/// What the notch shows while it rests. On a drawn notch every style applies. A real notch has the
/// camera in the middle, so only the strips beside it are free: it shows `card` when Card is picked
/// (the text beside the camera), and `classic` for every other style.
enum PillStyle: String, Codable, CaseIterable, Sendable {
    case card, classic, fish, streak, session

    /// Unknown values (written by a newer version) read as classic.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PillStyle(rawValue: raw) ?? .classic
    }

    var displayName: String {
        switch self {
        case .card: "Card"
        case .classic: "Classic"
        case .fish: "Swimming fish"
        case .streak: "Streak & daily goal"
        case .session: "Study session"
        }
    }

    /// One line, shown under the name in the picker, saying what this style shows.
    var summary: String {
        switch self {
        case .card: "The card you're learning, flipping between front and answer."
        case .classic: "Deck color and card position, like the notch on a Mac with a camera."
        case .fish: "A fish swims across the pill. When it reaches the end, the next card arrives."
        case .streak: "Your streak, this week, and how many cards you've studied today."
        case .session: "A timer for a focused session and how many cards you've reviewed."
        }
    }

    var symbolName: String {
        switch self {
        case .card: "rectangle.on.rectangle.angled"
        case .classic: "rectangle.stack"
        case .fish: "fish"
        case .streak: "flame"
        case .session: "timer"
        }
    }

    /// The styles people can pick today, in the order the picker lists them.
    static let available: [PillStyle] = [.card, .classic, .fish, .streak, .session]

    /// What a new install starts with.
    static let `default`: PillStyle = .card

    var isAvailable: Bool { Self.available.contains(self) }

    /// What to draw for a saved choice: a style that isn't available (a settings file from a newer
    /// version) falls back to classic.
    static func resolved(_ style: PillStyle) -> PillStyle { style.isAvailable ? style : .classic }

    /// What a real notch shows for a chosen style: Card beside the camera, Classic for the rest.
    static func onRealNotch(_ style: PillStyle) -> PillStyle { resolved(style) == .card ? .card : .classic }
}

/// "Flip every": how long each side of the resting Card notch shows before it flips.
enum NotchFlipInterval: Int, Codable, CaseIterable, Sendable {
    case off = 0
    case three = 3
    case five = 5
    case ten = 10

    static let `default`: NotchFlipInterval = .five

    /// Unknown values read as the default.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = NotchFlipInterval(rawValue: raw) ?? .default
    }

    /// Seconds per side; nil when off (the front stays).
    var seconds: TimeInterval? { self == .off ? nil : TimeInterval(rawValue) }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .three: "3 seconds"
        case .five: "5 seconds"
        case .ten: "10 seconds"
        }
    }

    /// The order the picker lists them.
    static let choices: [NotchFlipInterval] = [.three, .five, .ten, .off]
}

extension AppSettings {
    /// One-time move to the Card style (FLAS-94): Classic was the old default, so whoever has it
    /// gets Card; Fish, Streak and Session were picked on purpose and stay. Runs once, guarded by
    /// its own flag rather than a shared settings version. Returns whether anything changed, so the
    /// caller knows to save.
    mutating func migratePillStyleToCard() -> Bool {
        guard !didMigratePillStyleCard1 else { return false }
        didMigratePillStyleCard1 = true
        if pillStyle == .classic { pillStyle = .card }
        return true
    }
}

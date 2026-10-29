import CoreGraphics
import Foundation

/// Rules for the resting Card notch (FLAS-89): what each side shows, how long text fits, and when it
/// flips. Kept free of UI so they can be tested. The flip is only what the notch shows: nothing here
/// touches the shared playback state, the study log or the widgets.
enum NotchCardRest {
    /// The text's size, and the smallest it may shrink to before it slides.
    static let fontSize: CGFloat = 12
    static let minimumFontSize: CGFloat = 11
    /// Long text waits this long before it starts to slide...
    static let slideDelay: TimeInterval = 1
    /// ...slides at this speed (points per second) until its end shows...
    static let slideSpeed: CGFloat = 30
    /// ...and then holds this long before the side may flip.
    static let slideEndHold: TimeInterval = 1
    /// How far the edges of sliding text fade out.
    static let edgeFade: CGFloat = 8

    // MARK: What a side shows

    enum Face: Equatable, Sendable {
        /// Text on one line.
        case text(String)
        /// A side that is only a picture: a photo symbol and "Picture".
        case picture
        /// Nothing at all (an empty back).
        case empty

        var hasContent: Bool { self != .empty }
    }

    /// One line: line breaks become spaces, and the ends are trimmed.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func face(text: String, hasImage: Bool) -> Face {
        let line = oneLine(text)
        if !line.isEmpty { return .text(line) }
        return hasImage ? .picture : .empty
    }

    static func faces(of card: Card) -> (front: Face, back: Face) {
        (face(text: card.front, hasImage: card.frontImage != nil), face(text: card.back, hasImage: card.backImage != nil))
    }

    /// What VoiceOver reads for the resting Card notch. Always the front, so a flip is never announced.
    static func accessibilityLabel(for card: Card) -> String {
        switch faces(of: card).front {
        case .text(let text): "Card: \(text)"
        case .picture: "Card: Picture"
        case .empty: "Card"
        }
    }

    // MARK: Long text

    enum Fit: Equatable, Sendable {
        /// Fits on one line at this size, so it is centered (or right-aligned beside a camera).
        case fits(fontSize: CGFloat)
        /// Too long even at the smaller size: starts left-aligned and slides left by `overflow`.
        case slides(fontSize: CGFloat, overflow: CGFloat)
        /// Too long, with Reduce Motion on: cut off with an ellipsis instead of sliding.
        case truncates(fontSize: CGFloat)

        var fontSize: CGFloat {
            switch self {
            case .fits(let size), .slides(let size, _), .truncates(let size): size
            }
        }
    }

    /// - Parameter naturalWidth: the text's width on one line at `fontSize`.
    static func fit(naturalWidth: CGFloat, available: CGFloat, reduceMotion: Bool) -> Fit {
        if naturalWidth <= available { return .fits(fontSize: fontSize) }
        let shrunk = naturalWidth * minimumFontSize / fontSize
        if shrunk <= available { return .fits(fontSize: minimumFontSize) }
        if reduceMotion { return .truncates(fontSize: minimumFontSize) }
        return .slides(fontSize: minimumFontSize, overflow: (shrunk - available).rounded(.up))
    }

    /// How long a side's text takes from appearing to its end showing; 0 for text that doesn't slide.
    static func slideDuration(_ fit: Fit) -> TimeInterval {
        guard case .slides(_, let overflow) = fit else { return 0 }
        return slideDelay + TimeInterval(overflow / slideSpeed)
    }

    /// Where sliding text is, `elapsed` seconds after its side appeared: still for the delay, then
    /// left at `slideSpeed` until its end shows, then held.
    static func slideOffset(_ fit: Fit, elapsed: TimeInterval) -> CGFloat {
        guard case .slides(_, let overflow) = fit else { return 0 }
        let moving = max(elapsed - slideDelay, 0)
        return -min(CGFloat(moving) * slideSpeed, overflow)
    }

    // MARK: Flipping

    /// When the resting card flips. Elapsed time counts from when the card arrived or the notch last
    /// closed, which is always on the front.
    struct FlipPlan: Equatable, Sendable {
        /// How long each side stays; nil when the card never flips (flip off, or nothing on the back).
        var frontHold: TimeInterval?
        var backHold: TimeInterval?

        /// - Parameters:
        ///   - frontSlide / backSlide: `slideDuration` of each side; a side that slides longer than
        ///     the interval stays until its slide ends plus `slideEndHold`.
        init(interval: NotchFlipInterval, hasBack: Bool, frontSlide: TimeInterval = 0, backSlide: TimeInterval = 0) {
            guard let seconds = interval.seconds, hasBack else {
                frontHold = nil
                backHold = nil
                return
            }
            func hold(_ slide: TimeInterval) -> TimeInterval {
                slide > 0 ? max(seconds, slide + NotchCardRest.slideEndHold) : seconds
            }
            frontHold = hold(frontSlide)
            backHold = hold(backSlide)
        }

        var flips: Bool { frontHold != nil && backHold != nil }

        func side(at elapsed: TimeInterval) -> CardSide {
            guard let front = frontHold, let back = backHold, elapsed > 0 else { return .front }
            let into = elapsed.truncatingRemainder(dividingBy: front + back)
            return into < front ? .front : .back
        }

        /// How long the side showing at `elapsed` has been showing.
        func timeIntoSide(at elapsed: TimeInterval) -> TimeInterval {
            guard let front = frontHold, let back = backHold, elapsed > 0 else { return max(elapsed, 0) }
            let into = elapsed.truncatingRemainder(dividingBy: front + back)
            return into < front ? into : into - front
        }

        /// The next moment (in elapsed seconds) the side changes; nil if it never does.
        func nextChange(after elapsed: TimeInterval) -> TimeInterval? {
            guard let front = frontHold, let back = backHold else { return nil }
            let cycle = front + back
            let start = (max(elapsed, 0) / cycle).rounded(.down) * cycle
            for candidate in [start + front, start + cycle, start + cycle + front] where candidate > elapsed + 0.000_1 {
                return candidate
            }
            return start + 2 * cycle
        }
    }

    /// The flip: a vertical turn of about half a second, or with Reduce Motion a 0.3 s cross-fade.
    static func flipStyle(reduceMotion: Bool) -> NotchCard.FlipStyle { NotchCard.flipStyle(reduceMotion: reduceMotion) }

    static func flipDuration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0.3 : 0.5 }
}

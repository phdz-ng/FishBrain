import CoreGraphics
import Foundation

/// What the notch code needs to know about one display, in AppKit screen coordinates (origin at the
/// bottom left of the primary display, y up). Built from `NSScreen`; plain values so the placement
/// rules can be tested without a screen.
struct ScreenMetrics: Equatable, Sendable {
    var frame: CGRect
    var visibleFrame: CGRect
    /// `safeAreaInsets.top`: the notch's height on a notched Mac, 0 otherwise.
    var safeAreaTop: CGFloat
    /// The strips of the menu bar either side of the camera housing; nil on a Mac without a notch.
    var auxiliaryTopLeft: CGRect?
    var auxiliaryTopRight: CGRect?
    /// `CGDirectDisplayID`; identifies the display across changes to the screen list.
    var displayID: UInt32 = 0
    /// The Mac's own display (as opposed to a monitor plugged into it).
    var isBuiltIn = false

    /// A real camera housing, so the notch is not ours to draw.
    var hasRealNotch: Bool { safeAreaTop > 0 }

    /// The menu bar is hidden on this display: a full-screen app is in front, or the menu bar is set
    /// to hide itself. Only judged where we draw the notch: a real notch's strip stays on screen.
    var isMenuBarHidden: Bool { !hasRealNotch && frame.maxY - visibleFrame.maxY < 1 }
}

/// Where the notch is on a display, or where a notch-like pill belongs if there isn't one.
struct NotchPlacement: Equatable, Sendable {
    var screenFrame: CGRect
    /// The real notch on a notched Mac; otherwise a menu-bar-height pill centered at the top.
    var notchFrame: CGRect
    var hasNotch: Bool
    /// How wide the menu bar's strip left of the camera is (`auxiliaryTopLeft`); nil where there is
    /// no camera or it can't be measured.
    var leftStripWidth: CGFloat?

    /// A frame of the given size, centered on the notch and flush with the top of the display.
    func frame(size: CGSize) -> CGRect {
        CGRect(
            x: notchFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The resting panel: as tall as the notch, with a wing either side of it for the deck icon and
    /// the position.
    func collapsedFrame(wing: CGFloat = NotchGeometry.collapsedWing) -> CGRect {
        frame(size: CGSize(width: notchFrame.width + 2 * wing, height: notchFrame.height))
    }
}

extension NotchPlacement {
    /// `collapsedFrame` on whole points, which is what windows are snapped to. The height is rounded
    /// down (and the top kept flush with the display) so the panel never pokes below the menu bar.
    func alignedCollapsedFrame(wing: CGFloat = NotchGeometry.collapsedWing) -> CGRect {
        let exact = collapsedFrame(wing: wing)
        let height = exact.height.rounded(.down)
        let width = exact.width.rounded()
        return CGRect(x: (exact.midX - width / 2).rounded(), y: screenFrame.maxY - height, width: width, height: height)
    }
}

extension NotchPlacement {
    /// The resting pill where FishBrain draws the notch itself: no camera in the middle, so it is only
    /// as wide as its content. Whole points, flush with the top, never taller than the menu bar.
    func alignedDrawnFrame(width: CGFloat) -> CGRect {
        let height = notchFrame.height.rounded(.down)
        let width = width.rounded()
        return CGRect(x: (notchFrame.midX - width / 2).rounded(), y: screenFrame.maxY - height, width: width, height: height)
    }
}

extension NotchPlacement {
    /// The resting Card notch where FishBrain draws it: the size of a real MacBook notch, whatever the
    /// menu bar's height, so it hangs a little below a 24 pt menu bar the way a real one does. Whole
    /// points, centered, top flush with the display.
    func alignedCardFrame(size: CGSize = NotchGeometry.cardRestSize) -> CGRect {
        let width = size.width.rounded()
        let height = size.height.rounded()
        return CGRect(x: (notchFrame.midX - width / 2).rounded(), y: screenFrame.maxY - height, width: width, height: height)
    }

    /// The resting panel on a real notch with wings of different widths: the card text on the left
    /// of the camera, the deck color on the right. As tall as the notch (rounded down, top flush).
    func alignedSnugFrame(
        leftWing: CGFloat = NotchGeometry.snugTextWing, rightWing: CGFloat = NotchGeometry.collapsedWing
    ) -> CGRect {
        let height = notchFrame.height.rounded(.down)
        let minX = (notchFrame.minX - leftWing).rounded()
        let maxX = (notchFrame.maxX + rightWing).rounded()
        return CGRect(x: minX, y: screenFrame.maxY - height, width: maxX - minX, height: height)
    }

    /// How the Card style fits here: drawn, text beside the camera, or (where the menu bar's left
    /// strip is too narrow to give up a menu item's width) the deck color only.
    var cardLayout: CardRestLayout {
        guard hasNotch else { return .drawn }
        guard let strip = leftStripWidth, strip >= NotchGeometry.snugMinimumLeftStrip else { return .deckOnly }
        return .besideCamera
    }
}

/// Where the resting Card notch puts the card text.
enum CardRestLayout: Equatable, Sendable {
    /// A drawn 200 × 32 notch with the text centered in it.
    case drawn
    /// A real notch: the text in a wider wing left of the camera, the deck color on the right.
    case besideCamera
    /// A real notch whose menu bar has no room for the wider wing: the deck color only.
    case deckOnly

    /// The width the text gets, or nil where there is no text.
    var textWidth: CGFloat? {
        switch self {
        case .drawn: NotchGeometry.cardRestSize.width - 2 * NotchGeometry.cardTextPadding
        case .besideCamera: NotchGeometry.snugTextWing - 2 * NotchGeometry.snugTextPadding
        case .deckOnly: nil
        }
    }
}

enum NotchGeometry {
    /// The resting Card notch where FishBrain draws it: the size of a real MacBook notch.
    static let cardRestSize = CGSize(width: 200, height: 32)
    /// Padding either side of the card text in the drawn Card notch (176 pt for text).
    static let cardTextPadding: CGFloat = 12
    /// The wing left of a real camera that holds the card text ("Snug"), about one menu item wide.
    static let snugTextWing: CGFloat = 92
    /// Padding either side of the text in that wing (76 pt for text).
    static let snugTextPadding: CGFloat = 8
    /// The narrowest left menu-bar strip that still gives up `snugTextWing` for the card: the Apple
    /// menu, the app's name and a few menus still fit beside it. Narrower, the wing stays 34 pt.
    static let snugMinimumLeftStrip: CGFloat = 300
    /// Resting width of a drawn pill showing the deck icon and the position. Kept modest so it stays
    /// clear of app menus on small displays.
    static let drawnRestWidth: CGFloat = 150
    /// Resting width of the swimming-fish pill: the icon, a 92 pt track and the position.
    static let fishRestWidth: CGFloat = 195
    /// Resting width of the streak pill: the flame and streak, seven dots, and today's count.
    static let streakRestWidth: CGFloat = 285
    /// Resting width of the session pill: the ring, the time left and the cards reviewed; also the
    /// recap and "Last: 22 cards".
    static let sessionRestWidth: CGFloat = 200
    /// Resting width of a drawn pill with an offer: "Copied “sin embargo” + Make a card".
    static let bannerRestWidth: CGFloat = 285

    /// Used when the real notch width can't be measured, and as the pill width on Macs without one.
    static let fallbackNotchWidth: CGFloat = 200
    /// Menu bar height when it can't be measured (it is hidden, or the display has none).
    static let fallbackMenuBarHeight: CGFloat = 24
    static let collapsedWing: CGFloat = 34

    /// The display to put the panel on: the one with a notch if there is one, else the first
    /// (the primary display). Returns an index into `screens`.
    static func chooseScreen(_ screens: [ScreenMetrics]) -> Int? {
        screens.firstIndex { $0.safeAreaTop > 0 } ?? (screens.isEmpty ? nil : 0)
    }

    static func placement(for screen: ScreenMetrics) -> NotchPlacement {
        if screen.safeAreaTop > 0 {
            let height = screen.safeAreaTop
            let width: CGFloat
            let x: CGFloat
            // The notch is the gap between the two usable strips of the menu bar.
            if let left = screen.auxiliaryTopLeft, let right = screen.auxiliaryTopRight, right.minX > left.maxX {
                width = right.minX - left.maxX
                x = left.maxX
            } else {
                width = fallbackNotchWidth
                x = screen.frame.midX - width / 2
            }
            let notch = CGRect(x: x, y: screen.frame.maxY - height, width: width, height: height)
            return NotchPlacement(
                screenFrame: screen.frame, notchFrame: notch, hasNotch: true, leftStripWidth: screen.auxiliaryTopLeft?.width
            )
        }

        let measured = screen.frame.maxY - screen.visibleFrame.maxY
        let height = measured > 0 ? measured : fallbackMenuBarHeight
        let pill = CGRect(
            x: screen.frame.midX - fallbackNotchWidth / 2,
            y: screen.frame.maxY - height,
            width: fallbackNotchWidth,
            height: height
        )
        return NotchPlacement(screenFrame: screen.frame, notchFrame: pill, hasNotch: false)
    }
}

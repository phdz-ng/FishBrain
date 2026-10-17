import CoreGraphics
import Foundation

/// The settings that decide which displays get a notch.
struct NotchDisplayOptions: Equatable, Sendable {
    /// "Show in notch": the master switch.
    var showsNotch = true
    /// "Show on external displays".
    var showsOnExternalDisplays = false
    /// "Hide when an app is full screen".
    var hidesInFullScreen = true
    /// "Only on the display with the active menu bar".
    var onlyOnActiveDisplay = false
}

/// Which displays show a notch right now. Pure, so every combination of settings can be tested.
enum NotchDisplayPolicy {
    /// - Parameters:
    ///   - screens: every connected display; the first is the primary one (the one with the menu bar).
    ///   - activeDisplayID: the display whose menu bar is in use right now, if known.
    /// - Returns: the `displayID`s that should show a notch.
    static func displaysToShow(screens: [ScreenMetrics], activeDisplayID: UInt32?, options: NotchDisplayOptions) -> Set<UInt32> {
        guard options.showsNotch else { return [] }
        // A desktop Mac, or a laptop with its lid closed, has no display of its own: the primary
        // monitor stands in for it, so the notch doesn't vanish from a Mac that has only monitors.
        let hasOwnDisplay = screens.contains { $0.isBuiltIn || $0.hasRealNotch }

        var shown = Set<UInt32>()
        for (index, screen) in screens.enumerated() {
            let isOwnDisplay = screen.isBuiltIn || screen.hasRealNotch
            let standsInForOwn = !hasOwnDisplay && index == 0
            guard isOwnDisplay || standsInForOwn || options.showsOnExternalDisplays else { continue }
            if options.hidesInFullScreen && screen.isMenuBarHidden { continue }
            if options.onlyOnActiveDisplay, let activeDisplayID, screen.displayID != activeDisplayID { continue }
            shown.insert(screen.displayID)
        }
        return shown
    }
}

enum ActiveDisplay {
    /// The display holding the middle of a window, given the window's bounds in Core Graphics
    /// coordinates (origin at the top left of the primary display, y down). `screens[0]` is the
    /// primary display, whose height is the flip between the two coordinate systems.
    static func displayID(forWindowBounds bounds: CGRect, screens: [ScreenMetrics]) -> UInt32? {
        guard let primary = screens.first else { return nil }
        let center = CGPoint(x: bounds.midX, y: primary.frame.maxY - bounds.midY)
        return screens.first { $0.frame.contains(center) }?.displayID
    }
}

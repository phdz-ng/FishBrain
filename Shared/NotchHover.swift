import CoreGraphics
import Foundation

/// When the pointer should open and close the notch. Pure rules so they can be tested; the app
/// feeds them the pointer position from a global mouse-moved monitor.
enum NotchHover {
    /// How far outside the resting panel the pointer may be and still count as on it.
    static let hotZoneInset: CGFloat = 2
    /// How far outside the open panel the pointer must be before it closes, so it doesn't flicker
    /// when the pointer brushes the edge.
    static let collapseMargin: CGFloat = 12

    /// Pointer on the resting panel. The top edge counts: the pointer can sit right on the display's
    /// top edge, which a plain `contains` (half-open) would miss.
    static func shouldExpand(pointer: CGPoint, collapsedFrame: CGRect) -> Bool {
        pointer.x >= collapsedFrame.minX - hotZoneInset
            && pointer.x <= collapsedFrame.maxX + hotZoneInset
            && pointer.y >= collapsedFrame.minY - hotZoneInset
            && pointer.y <= collapsedFrame.maxY + hotZoneInset
    }

    /// Pointer clearly off the open panel.
    static func shouldCollapse(pointer: CGPoint, expandedFrame: CGRect) -> Bool {
        pointer.x < expandedFrame.minX - collapseMargin
            || pointer.x > expandedFrame.maxX + collapseMargin
            || pointer.y < expandedFrame.minY - collapseMargin
    }
}

extension NotchGeometry {
    /// The open panel's size, from the design.
    static let expandedSize = CGSize(width: 420, height: 282)

    /// Resting width of a drawn pill; grows for long positions like `wing(forPositionText:)` does.
    /// The fish needs room to swim, and the streak pill has more to say.
    static func drawnWidth(forPositionText text: String?, style: PillStyle = .classic) -> CGFloat {
        switch style {
        case .fish: return fishRestWidth + (wing(forPositionText: text) - collapsedWing)
        // The streak pill shows no position, so it doesn't grow for one.
        case .streak: return streakRestWidth
        case .session: return sessionRestWidth
        case .classic: return drawnRestWidth + (wing(forPositionText: text) - collapsedWing)
        // A fixed size, like the real notch it copies; long text shrinks and slides instead.
        case .card: return cardRestSize.width
        }
    }

    /// The strip of the resting panel on each side of the camera. It grows for long positions
    /// ("123/456") so the text never runs into the notch.
    static func wing(forPositionText text: String?) -> CGFloat {
        switch text?.count ?? 0 {
        case 0...5: collapsedWing
        case 6...7: collapsedWing + 10
        default: collapsedWing + 20
        }
    }
}

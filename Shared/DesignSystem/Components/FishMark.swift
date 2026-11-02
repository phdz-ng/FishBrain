import SwiftUI

/// The mark's shapes, drawn in a 200 x 320 design box (y down) and scaled to fit `rect`: a wide body and a small
/// tail below it, each a lozenge with its corners rounded. `half` keeps one side of the split at x = 100.
struct FishMarkShape: Shape {
    enum Half { case left, right }

    var half: Half?
    var roundsCorners = true

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 200, rect.height / 320)
        let origin = CGPoint(x: rect.midX - 100 * scale, y: rect.midY - 160 * scale)
        func lozenge(_ corners: [CGPoint], radius: CGFloat) -> Path {
            let points = corners.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) }
            var path = Path()
            guard roundsCorners else {
                path.addLines(points)
                path.closeSubpath()
                return path
            }
            let last = points[points.count - 1]
            path.move(to: CGPoint(x: (last.x + points[0].x) / 2, y: (last.y + points[0].y) / 2))
            for (index, corner) in points.enumerated() {
                path.addArc(tangent1End: corner, tangent2End: points[(index + 1) % points.count], radius: radius * scale)
            }
            path.closeSubpath()
            return path
        }
        var path = lozenge([CGPoint(x: 100, y: 20), CGPoint(x: 178, y: 120), CGPoint(x: 100, y: 220), CGPoint(x: 22, y: 120)], radius: 10)
        path.addPath(lozenge([CGPoint(x: 100, y: 234), CGPoint(x: 130, y: 268), CGPoint(x: 100, y: 302), CGPoint(x: 70, y: 268)], radius: 6))
        guard let half else { return path }
        let split = origin.x + 100 * scale
        let side = half == .left
            ? CGRect(x: rect.minX - rect.width, y: rect.minY - rect.height, width: split - rect.minX + rect.width, height: rect.height * 3)
            : CGRect(x: split, y: rect.minY - rect.height, width: rect.width * 3, height: rect.height * 3)
        return path.intersection(Path(side))
    }
}

/// The eye, on the split at (100, 78) in the design box.
struct FishMarkEye: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 200, rect.height / 320)
        let center = CGPoint(x: rect.midX, y: rect.midY - 160 * scale + 78 * scale)
        return Path(ellipseIn: CGRect(x: center.x - 14 * scale, y: center.y - 14 * scale, width: 28 * scale, height: 28 * scale))
    }
}

/// The FishBrain logo: a fish swimming up, two lozenges split down the middle into two halves, which read as two
/// brain hemispheres or a card mid-flip. It is drawn as vector shapes and sized by its frame, which it fills at a
/// 200 : 320 aspect ratio. In the default `.split` style the left half is the accent's `light` and the right half its
/// `fill`, so the mark follows the accent and the theme. Under 20 pt tall the eye is left out and the corners are
/// sharp, as in the 16 px app icon.
///
/// It is decorative and hidden from VoiceOver unless the caller gives it a `label`.
struct FishMark: View {
    enum Style: Equatable {
        /// Two halves in the accent's `light` and `fill`.
        case split
        /// One color, for single-color uses.
        case solid(Token)
    }

    static let aspectRatio: CGFloat = 200 / 320
    /// Below this height, in points, the mark is simplified.
    static let compactHeight: CGFloat = 20

    var style: Style = .split
    var showsEye = true
    var label: String?

    @Environment(\.accentChoice) private var accent

    /// Whether the mark is simplified (sharp corners, no eye) at this height.
    static func isCompact(height: CGFloat) -> Bool { height < compactHeight }

    /// Whether the eye is drawn: asked for, and not too small to see.
    static func drawsEye(showsEye: Bool, height: CGFloat) -> Bool { showsEye && !isCompact(height: height) }

    /// The mark is skipped by VoiceOver unless it has a label.
    static func isHiddenFromVoiceOver(label: String?) -> Bool { label == nil }

    var body: some View {
        GeometryReader { proxy in
            let rounds = !Self.isCompact(height: proxy.size.height)
            ZStack {
                switch style {
                case .split:
                    FishMarkShape(roundsCorners: rounds).fill(accent.light)
                    FishMarkShape(half: .right, roundsCorners: rounds).fill(accent.fill)
                case .solid(let token):
                    FishMarkShape(roundsCorners: rounds).fill(token)
                }
                if Self.drawsEye(showsEye: showsEye, height: proxy.size.height) {
                    FishMarkEye().fill(Theme.TextColor.primary)
                }
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .accessibilityHidden(Self.isHiddenFromVoiceOver(label: label))
        .accessibilityLabel(label ?? "")
    }
}

#Preview("FishMark, every accent") {
    VStack(spacing: 20) {
        ForEach([ColorScheme.dark, .light], id: \.self) { scheme in
            HStack(spacing: 28) {
                ForEach(AccentChoice.allCases, id: \.self) { accent in
                    VStack(spacing: 10) {
                        FishMark().frame(height: 96)
                        FishMark().frame(height: 32)
                        FishMark().frame(height: 16)
                        FishMark(style: .solid(accent.fill), showsEye: false).frame(height: 32)
                    }
                    .environment(\.accentChoice, accent)
                }
            }
            .padding(24)
            .background(scheme == .dark ? Theme.Surface.previewBackdrop.color : .white)
            .environment(\.colorScheme, scheme)
        }
    }
}

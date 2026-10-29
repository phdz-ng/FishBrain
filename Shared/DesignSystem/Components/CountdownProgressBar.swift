import SwiftUI

/// Thin capsule bar showing how far through the current 5-minute slot we are.
struct CountdownProgressBar: View {
    /// 0...1; values outside are clamped.
    var progress: Double
    var height: CGFloat = 4

    @Environment(\.accentChoice) private var accent

    static func clamped(_ progress: Double) -> Double {
        progress.isNaN ? 0 : min(max(progress, 0), 1)
    }

    /// The fill's width. If the layout ever hands over an unusable width (infinite or NaN, as WidgetKit
    /// can while laying out a widget), draw nothing rather than a NaN that crashes SwiftUI's layout.
    static func fillWidth(trackWidth: CGFloat, progress: Double) -> CGFloat {
        guard trackWidth.isFinite, trackWidth > 0 else { return 0 }
        return trackWidth * CGFloat(clamped(progress))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Surface.progressTrack)
                Capsule()
                    .fill(accent.light)
                    .frame(width: Self.fillWidth(trackWidth: proxy.size.width, progress: progress))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Time until next card")
        .accessibilityValue(Text(Self.clamped(progress), format: .percent.precision(.fractionLength(0))))
    }
}

#Preview("CountdownProgressBar") {
    VStack(spacing: 16) {
        CountdownProgressBar(progress: 0.62)
        CountdownProgressBar(progress: 0.2, height: 3)
        CountdownProgressBar(progress: 1)
    }
    .frame(width: 240)
    .appearancePreview()
}

import SwiftUI

/// Grouped-list container: translucent glass (smoked in dark, near-white in light) with a hairline border.
struct GlassPanel<Content: View>: View {
    var cornerRadius: CGFloat = Theme.Radius.group
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    Rectangle().fill(Theme.Blur.group)
                    Rectangle().fill(Theme.Surface.group)
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
    }
}

/// Row separator inside a `GlassPanel`.
struct HairlineDivider: View {
    var body: some View {
        Rectangle().fill(Theme.Surface.hairline).frame(height: 0.5)
    }
}

#Preview("GlassPanel") {
    GlassPanel {
        VStack(spacing: 0) {
            Text("la mariposa").padding(14)
            HairlineDivider()
            Text("el desayuno").padding(14)
        }
        .font(Theme.Typography.body)
        .foregroundStyle(Theme.TextColor.primary)
        .frame(width: 280)
    }
    .appearancePreview()
}

import SwiftUI

extension View {
    /// For previews: the view in light and in dark side by side, each on the preview backdrop.
    func appearancePreview() -> some View {
        HStack(spacing: 0) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                self
                    .padding(24)
                    .background(Theme.Surface.previewBackdrop)
                    .environment(\.colorScheme, scheme)
            }
        }
    }
}

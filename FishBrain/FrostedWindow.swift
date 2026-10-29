import AppKit
import SwiftUI

/// Behind-window blur: the desktop shows through, tinted by `Theme.Surface.window` on top. The HUD
/// material is dark; light uses the plain window material under its near-white tint. With Reduce
/// Transparency macOS draws either one solid.
struct FrostedWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = Self.material(for: context.environment.colorScheme)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = Self.material(for: context.environment.colorScheme)
    }

    static func material(for scheme: ColorScheme) -> NSVisualEffectView.Material {
        scheme == .dark ? .hudWindow : .underWindowBackground
    }
}

/// Makes the hosting window transparent so the blur above can show, and lets the content run
/// under the (hidden) title bar.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ConfiguringView()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        }
    }
}

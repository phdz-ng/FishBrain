import AppKit

#if DEBUG
/// `-FishBrainPrintAccessibility`: what VoiceOver is given. Walks the app's own accessibility tree
/// (no permission needed for your own process) for the main window and the notch, resting and open.
enum AccessibilityReport {
    @MainActor
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Tell AppKit an assistive client is present, which makes SwiftUI build its tree.
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            NSApp.accessibilitySetOverrideValue(true, forAttribute: NSAccessibility.Attribute(rawValue: attribute))
        }
        guard let controller = NotchDisplayManager.shared.controllers.values.first else {
            Swift.print("No notch on screen")
            return
        }
        func windows() -> [NSWindow] {
            NSApp.windows.filter { ($0.styleMask.contains(.titled) && $0.isVisible) || $0 === controller.panel }
        }
        // SwiftUI builds its accessibility tree on first request and fills it in a moment later, so
        // ask once, wait, then read.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            windows().forEach { silentWalk($0, depth: 0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            Swift.print("=== Notch, at rest")
            if let panel = controller.panel { dump(panel, depth: 0) }
            controller.expand()
            windows().forEach { silentWalk($0, depth: 0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            Swift.print("\n=== Notch, open")
            if let panel = controller.panel { dump(panel, depth: 0) }
            // Several passes over the main window before reading it.
            for i in 1...5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) {
                    NSApp.windows.filter { $0.styleMask.contains(.titled) && $0.isVisible }.forEach { silentWalk($0, depth: 0) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                Swift.print("\n=== Main window")
                for window in NSApp.windows where window.styleMask.contains(.titled) && window.isVisible { dump(window, depth: 0) }
                Swift.print("=== done")
                exit(0)
            }
        }
    }

    private static func silentWalk(_ element: Any, depth: Int) {
        guard depth < 14 else { return }
        for child in ((element as AnyObject).accessibilityChildren?() as? [Any]) ?? [] { silentWalk(child, depth: depth + 1) }
    }

    private static func dump(_ element: Any, depth: Int) {
        guard depth < 14 else { return }
        let object = element as AnyObject
        let role = (object.accessibilityRole?()?.rawValue ?? "").replacingOccurrences(of: "AX", with: "")
        let label = object.accessibilityLabel?() ?? nil
        let title = object.accessibilityTitle?() ?? nil
        let value = object.accessibilityValue?().flatMap { "\($0)" }
        let hidden = (object.isAccessibilityElement?() ?? true) == false && depth > 0
        let text = [label, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
        if !text.isEmpty || (value?.isEmpty == false) || role == "Button" || role == "CheckBox" || role == "PopUpButton" || role == "MenuButton" {
            let pad = String(repeating: "  ", count: min(depth, 8))
            Swift.print("\(pad)[\(role.isEmpty ? "?" : role)] \(text)\(value.map { $0.isEmpty ? "" : "  = \($0)" } ?? "")\(hidden ? "  (not an element)" : "")")
        }
        let children = (object.accessibilityChildren?() as? [Any]) ?? []
        for child in children { dump(child, depth: depth + 1) }
    }
}
#endif

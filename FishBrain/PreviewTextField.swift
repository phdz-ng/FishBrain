import AppKit
import SwiftUI

/// The editing field on the Now showing card: multi-line, centered, in the card's own font. Return
/// saves, Shift+Return starts a new line and Esc cancels (`PreviewFieldKey`). It takes focus when it
/// appears, with the caret at the end, and grows with its text up to the room it is given, then scrolls.
///
/// An `NSTextView` rather than a SwiftUI `TextField`: a vertical `TextField` can't tell Return from
/// Shift+Return or center its lines.
struct PreviewTextField: NSViewRepresentable {
    @Binding var text: String
    var side: CardSide
    var font: NSFont
    var textColor: Token
    var caretColor: Token
    var onSave: () -> Void
    var onCancel: () -> Void

    /// What VoiceOver calls the field: "Front, text field".
    static func accessibilityLabel(_ side: CardSide) -> String { side == .front ? "Front" : "Back" }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = FieldTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.string = text

        let scrollView = FieldScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        apply(to: textView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        apply(to: textView, context: context)
    }

    private func apply(to textView: NSTextView, context: Context) {
        let color = textColor.nsColor(in: context.environment)
        textView.font = font
        textView.textColor = color
        textView.alignment = .center
        textView.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: Self.centered]
        textView.insertionPointColor = caretColor.nsColor(in: context.environment)
        textView.setAccessibilityLabel(Self.accessibilityLabel(side))
    }

    private static let centered: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()

    /// As tall as the text at the width offered, at least one line, and no taller than the room there is.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = nsView.documentView as? NSTextView,
              let container = textView.textContainer, let layout = textView.layoutManager else { return nil }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 240
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: font)
        let height = max(ceil(layout.usedRect(for: container).height), ceil(lineHeight))
        let limit = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? height
        return CGSize(width: width, height: min(height, max(limit, lineHeight)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PreviewTextField
        /// Typing's own undo, so ⌘Z in the field steps back through the draft and nothing it typed is
        /// left on the window's undo stack once the field is gone.
        private let typingUndo = UndoManager()

        init(_ parent: PreviewTextField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func undoManager(for view: NSTextView) -> UndoManager? { typingUndo }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            switch PreviewFieldKey.action(for: selector, shift: shift) {
            case .save:
                parent.onSave()
                return true
            case .newLine:
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case .cancel:
                parent.onCancel()
                return true
            case nil:
                return false
            }
        }
    }
}

/// Reads as a text field to VoiceOver ("Front, text field"), and takes focus, caret at the end, as soon
/// as it is in a window.
private final class FieldTextView: NSTextView {
    private var hasTakenFocus = false

    override func accessibilityRole() -> NSAccessibility.Role? { .textField }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasTakenFocus else { return }
        hasTakenFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
        }
    }
}

/// The scroll view only clips and scrolls; VoiceOver goes straight to the field inside.
private final class FieldScrollView: NSScrollView {
    override func isAccessibilityElement() -> Bool { false }
}

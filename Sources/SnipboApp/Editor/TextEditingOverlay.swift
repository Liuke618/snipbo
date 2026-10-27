import AppKit
import SnipboCore

extension NSColor {
    /// Converts a document color to the AppKit color used by the editor UI.
    convenience init(_ rgba: RGBA) {
        self.init(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}

/// Single-line text entry shown on the canvas while the text tool is active.
///
/// Return commits and Escape cancels, except while an input method has marked
/// (composing) text: then the key events go to AppKit so the input method can
/// confirm or cancel the composition instead of ending the annotation.
@MainActor
final class TextEditingOverlay: NSTextView {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// Grows the editor as wrapped or multi-line text is typed. The canvas
    /// owns the origin; only the height changes.
    private let minimumHeight: CGFloat = 32

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36:
            // Shift/Option+Return inserts a line break; plain Return commits,
            // matching the single-key workflow of the other tools.
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewline(nil)
            } else {
                onCommit?(string)
            }
        case 53:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        resizeToFitContent()
    }

    private func resizeToFitContent() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let target = max(minimumHeight, ceil(used + 4))
        guard abs(frame.height - target) > 0.5 else { return }
        var next = frame
        next.size.height = target
        frame = next
    }
}

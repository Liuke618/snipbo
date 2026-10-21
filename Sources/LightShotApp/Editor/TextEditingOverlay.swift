import AppKit
import LightShotCore

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

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36:
            onCommit?(string)
        case 53:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}

import AppKit
import SnipboCore
import SwiftUI

/// SwiftUI wrapper around the AppKit shortcut recorder.
@MainActor
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var hotkey: Hotkey

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.hotkey = hotkey
        view.onChange = { hotkey = $0 }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.hotkey = hotkey
        nsView.onChange = { hotkey = $0 }
    }
}

/// Recorder for an optional per-mode shortcut: `nil` renders the disabled
/// state, and recording a chord while disabled enables the mode.
@MainActor
struct ModeHotkeyRecorderView: NSViewRepresentable {
    let hotkey: Hotkey?
    let onChange: (Hotkey?) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.hotkey = hotkey
        view.onChange = { onChange($0) }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.hotkey = hotkey
        nsView.onChange = { onChange($0) }
    }
}

/// Click-to-record control. It draws the current shortcut, and only while
/// armed by a click it captures the next key combination that includes at
/// least one of Command/Shift/Option/Control and reports it through `onChange`.
/// Escape or losing first responder leaves recording mode without changing the
/// shortcut; keys pressed while not recording pass through to the responder
/// chain.
final class HotkeyRecorderNSView: NSView {
    var hotkey: Hotkey? {
        didSet { needsDisplay = true }
    }
    var onChange: ((Hotkey) -> Void)?
    private var recording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 32) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let text: String
        let textColor: NSColor
        if recording {
            text = "Press a shortcut…"
            textColor = .labelColor
        } else if let hotkey {
            text = hotkey.displayString
            textColor = .labelColor
        } else {
            text = "Off — record to enable"
            textColor = .secondaryLabelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: textColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: 8, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        // Only keys pressed while armed are recorded; anything else must keep
        // its normal meaning (Command+W/Q/S and the rest of the menu chords).
        guard recording else {
            super.keyDown(with: event)
            return
        }
        // Auto-repeat must not re-trigger the save/notify chain.
        if event.isARepeat {
            return
        }
        if event.keyCode == 53 {
            recording = false
            needsDisplay = true
            return
        }
        // Only Command/Shift/Option/Control form a valid global shortcut.
        // Looking at those alone also keeps Caps Lock (and other independent
        // flags) from turning a bare key press into a modifier-less hotkey.
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.isEmpty {
            NSSound.beep()
            return
        }
        let hotkey = Hotkey(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers(flags)
        )
        self.hotkey = hotkey
        recording = false
        onChange?(hotkey)
        needsDisplay = true
    }

    func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var result: HotkeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}

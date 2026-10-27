import AppKit

/// Capsule button for dark HUD surfaces (recording / scrolling controls).
@MainActor
final class PillButton: NSButton {
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ])
        return NSSize(width: text.width + 24, height: 22)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat
        if isHighlighted {
            alpha = DesignTokens.Alpha.pillPress
        } else if isHovered {
            alpha = DesignTokens.Alpha.pressed
        } else {
            alpha = DesignTokens.Alpha.pillOnDark
        }
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        ).fill()
        super.draw(dirtyRect)
    }
}

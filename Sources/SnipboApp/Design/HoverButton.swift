import AppKit

/// Borderless icon button with the unified hover and selected states. Template
/// icons follow the effective appearance.
@MainActor
class HoverButton: NSButton {
    var showsSelected = false {
        didSet { needsDisplay = true }
    }

    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        if showsSelected || isHovered {
            let alpha = showsSelected ? DesignTokens.Alpha.selected : DesignTokens.Alpha.hover
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                xRadius: DesignTokens.Radius.control,
                yRadius: DesignTokens.Radius.control
            ).fill()
        }
        super.draw(dirtyRect)
    }
}

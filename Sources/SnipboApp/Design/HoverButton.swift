import AppKit

/// Borderless button that paints its own background washes for every
/// interaction state: resting (only when `baseFillAlpha` is set), hover, press
/// and selected. Template icons follow the effective appearance.
///
/// Subclasses (`PillButton`, `ReadoutPillButton`) change only geometry and
/// colours through the read-only hooks below; the tracking-area plumbing and the
/// state precedence live here so no control reimplements hover feedback.
@MainActor
class HoverButton: NSButton {
    var showsSelected = false {
        didSet { needsDisplay = true }
    }

    /// Alpha of the resting background, or `nil` for no resting background —
    /// the wash then appears only on hover and press. Capsule controls set a
    /// base fill so they stay visible while idle.
    var baseFillAlpha: CGFloat? {
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

    // MARK: Paint hooks

    /// Colour of the hover and press washes.
    var washColor: NSColor { .white }
    /// Colour of the selected wash; the violet accent marks the active tool.
    var selectedWashColor: NSColor { DesignTokens.Color.accentSoft }
    /// Corner radius of the wash; capsules override with half the height.
    var washRadius: CGFloat { DesignTokens.Radius.control }
    /// How far the wash sits inside the bounds.
    var washInset: CGFloat { 1 }
    var hoverAlpha: CGFloat { DesignTokens.Alpha.hover }
    var selectedAlpha: CGFloat = 1
    var pressedAlpha: CGFloat { DesignTokens.Alpha.pressed }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // A panel that resigns key while the pointer is inside never delivers
        // mouseExited, so rebuilding the area is the point where a stale hover
        // wash has to be dropped; otherwise it sticks until the next enter.
        if isHovered {
            isHovered = false
            needsDisplay = true
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

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let wash: (color: NSColor, alpha: CGFloat)?
        if isHighlighted {
            wash = (washColor, pressedAlpha)
        } else if showsSelected {
            wash = (selectedWashColor, selectedAlpha)
        } else if isHovered {
            wash = (washColor, hoverAlpha)
        } else {
            wash = baseFillAlpha.map { (washColor, $0) }
        }

        if let wash {
            wash.color.withAlphaComponent(wash.alpha).setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: washInset, dy: washInset),
                xRadius: washRadius,
                yRadius: washRadius
            ).fill()
        }
        super.draw(dirtyRect)
    }
}

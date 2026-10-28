import AppKit

/// Fixed dark fill behind toolbars and floating panels, from the design token
/// palette. It is click-through on its own surface, so buttons on top and
/// window dragging behind keep working.
///
/// This was an `NSVisualEffectView` when surfaces followed the system
/// appearance; the fixed dark palette replaces materials with literal fills,
/// which also keeps borderless HUDs readable (a `withinWindow` material has
/// nothing to blur in a transparent panel and renders as an opaque plate).
@MainActor
final class MaterialBackgroundView: NSView {
    private let fill: NSColor
    private let cornerRadius: CGFloat
    private let bottomHairline: Bool
    private let stroked: Bool

    init(
        cornerRadius: CGFloat = 0,
        fill: NSColor = DesignTokens.Color.surface,
        bottomHairline: Bool = false,
        stroke: Bool = false
    ) {
        self.fill = fill
        self.cornerRadius = cornerRadius
        self.bottomHairline = bottomHairline
        self.stroked = stroke
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Ignores clicks that land on the fill itself, so the surface behind
    /// (a window drag, the canvas) still gets them. Returning `nil` outright
    /// would prune the whole subtree, which silently kills any control
    /// hosted inside the plate.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        fill.setFill()
        path.fill()
        if stroked {
            DesignTokens.Color.stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        if bottomHairline {
            DesignTokens.Color.stroke.setFill()
            NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1).fill()
        }
    }
}

import AppKit

/// Material fill behind toolbars and floating panels. It never takes mouse
/// events, so buttons and window dragging on top keep working.
@MainActor
final class MaterialBackgroundView: NSVisualEffectView {
    init(material: NSVisualEffectView.Material, cornerRadius: CGFloat = 0) {
        super.init(frame: .zero)
        self.material = material
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = cornerRadius > 0
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

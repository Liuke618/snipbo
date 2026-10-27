import AppKit

/// Fixed dark translucent plate behind the capture HUDs (recording bar,
/// scrolling bar, countdown).
///
/// `MaterialBackgroundView` cannot serve here: with `blendingMode =
/// .withinWindow` an `NSVisualEffectView` has nothing to blur inside a
/// transparent borderless panel, so it renders as an opaque plate that is light
/// in the light system appearance — the white labels, pills and hairline would
/// all be unreadable. The spec's pre-authorized fallback is this dark 78% fill,
/// which is appearance-independent by construction (the same reason the capture
/// overlays use fixed black/white). Like the material view it never takes mouse
/// events, so the controls on top keep working.
@MainActor
final class HudBackgroundView: NSView {
    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = DesignTokens.hudFill.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = DesignTokens.hudBorder.cgColor
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

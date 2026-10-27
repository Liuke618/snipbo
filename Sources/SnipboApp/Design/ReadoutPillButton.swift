import AppKit

/// The editor toolbar's live size readout as a compact capsule. It is a real
/// control — clicking it opens the resize popover — so it paints the unified
/// three states: a faint resting fill, hover over it, and a stronger press wash.
@MainActor
final class ReadoutPillButton: HoverButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        imagePosition = .noImage
        baseFillAlpha = DesignTokens.Alpha.readoutFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The readout fills its whole frame, unlike the inset icon washes.
    override var washInset: CGFloat { 0 }
}

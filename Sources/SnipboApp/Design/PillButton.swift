import AppKit

/// Capsule button for dark HUD surfaces (recording / scrolling controls).
///
/// `filled` is the primary action: a white capsule that is visible at rest.
/// `plain` is the quiet second action (Cancel): the same 22pt capsule geometry
/// and the same hover/press washes, but no resting background and a dimmed
/// title. Both styles keep the full capsule as the hit target — a borderless
/// `NSButton` sized to its title would otherwise shrink the clickable area.
@MainActor
final class PillButton: HoverButton {
    enum Style {
        case filled
        case plain

        var titleColor: NSColor {
            switch self {
            case .filled: return .white
            case .plain: return NSColor.white.withAlphaComponent(0.62)
            }
        }

        /// A plain pill has no resting background; only the washes show.
        var restAlpha: CGFloat? {
            switch self {
            case .filled: return DesignTokens.Alpha.pillOnDark
            case .plain: return nil
            }
        }
    }

    private static let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    init(
        title: String,
        target: AnyObject?,
        action: Selector?,
        style: Style = .filled
    ) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        imagePosition = .noImage
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Self.titleFont,
            .foregroundColor: style.titleColor,
        ])
        baseFillAlpha = style.restAlpha
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [
            .font: Self.titleFont,
        ])
        return NSSize(width: text.width + 24, height: 22)
    }

    override var washColor: NSColor { .white }
    override var washRadius: CGFloat { bounds.height / 2 }
    override var washInset: CGFloat { 0 }
    override var hoverAlpha: CGFloat { DesignTokens.Alpha.pillHover }
    override var pressedAlpha: CGFloat { DesignTokens.Alpha.pillPress }
}

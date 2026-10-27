import AppKit

/// Shared visual constants for the unified system-native look. Views must not
/// invent their own corner radii, spacings, or alpha levels — every value here
/// comes from the design token table.
@MainActor
enum DesignTokens {
    /// Corner-radius scale: 6 / 8 / 10 / 12 / 16 / 999, one step per surface
    /// size — `control` (buttons, wells), `card` (thumbnail), `panel` (floating
    /// panel, editor toolbar), `hud` (the recording and scrolling control bars),
    /// `hudLarge` (the countdown plate, the tallest floating surface), and 999
    /// for fully round capsules.
    /// The step is deliberate: a bigger surface needs a softer corner.
    /// The 999 step is not a stored constant: a capsule is drawn from the
    /// control's own height (`bounds.height / 2`), because `NSBezierPath` does
    /// not clamp an oversized radius the way `CALayer.cornerRadius` does.
    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 8
        static let panel: CGFloat = 10
        /// Recording and scrolling control bars.
        static let hud: CGFloat = 12
        /// The countdown plate.
        static let hudLarge: CGFloat = 16
    }

    enum Spacing {
        static let icon: CGFloat = 4
        static let tight: CGFloat = 8
    }

    enum Alpha {
        static let hover: CGFloat = 0.07
        static let selected: CGFloat = 0.14
        static let pressed: CGFloat = 0.22
        /// Capsule buttons on dark HUD surfaces.
        static let pillOnDark: CGFloat = 0.16
        /// Capsule hover on dark HUD surfaces.
        static let pillHover: CGFloat = 0.22
        /// Capsule press on dark HUD surfaces.
        static let pillPress: CGFloat = 0.28
        /// Resting fill of the editor toolbar's size readout capsule.
        static let readoutFill: CGFloat = 0.06
    }

    enum Shadow {
        static let panelOpacity: Float = 0.28
        static let panelRadius: CGFloat = 12
        static let cardOpacity: Float = 0.06
        static let cardRadius: CGFloat = 2
        static let cardHoverOpacity: Float = 0.13
        static let cardHoverRadius: CGFloat = 14
    }

    /// Fixed white/black for overlays drawn on top of screenshot content; these
    /// intentionally do not follow the system appearance.
    static let overlayDim: CGFloat = 0.45
    static let overlayFill = NSColor.black.withAlphaComponent(0.72)
    /// Hairline around a white selection handle, so it stays visible on light
    /// content.
    static let overlayHandleStroke: CGFloat = 0.4
    /// Outer ring of the magnifier lens, drawn over the white outline.
    static let overlayLensRing: CGFloat = 0.2

    /// Fixed dark fill behind the capture HUDs. A material cannot be used there:
    /// with `blendingMode = .withinWindow` an `NSVisualEffectView` has nothing to
    /// blur inside a transparent borderless panel, so it renders as an opaque
    /// plate that is light in light appearance. This fill keeps the HUDs
    /// appearance-independent, which is what their white labels, pills and
    /// hairline are designed against.
    static let hudFill = NSColor.black.withAlphaComponent(0.78)
    /// 1pt hairline around a HUD plate.
    static let hudBorder = NSColor.white.withAlphaComponent(0.12)

    static let readoutFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// Secondary lines: recognition status counts, meta captions.
    static let metaFont = NSFont.systemFont(ofSize: 11)
}

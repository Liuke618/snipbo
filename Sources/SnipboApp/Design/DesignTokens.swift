import AppKit

/// Shared visual constants. Views must not invent their own corner radii,
/// spacings, or alpha levels — every value here comes from the design token
/// table.
///
/// Every `Color` role is a dynamic `NSColor` carrying a light and a dark
/// variant. `AppDelegate.applyAppearance` pins the app appearance to the
/// user's theme setting (system / light / dark), so a draw-time token read
/// always resolves to the active theme, and AppKit redraws such views for
/// free when the theme flips. Views that cache a resolved color instead —
/// layer `CGColor`s, pattern images — must override
/// `viewDidChangeEffectiveAppearance()` and rebuild.
///
/// Tokens painted over screenshot content — the capture overlay, the HUD
/// plates, `PillButton` — stay fixed on purpose: they are designed against
/// dark fills, and their backdrop is the screenshot, not the UI theme.
@MainActor
enum DesignTokens {
    /// Fixed violet for the locked-window ring drawn over screenshot content;
    /// the overlay must not follow the UI theme the way `Color.accent` does.
    static let overlayAccent = Color.fixed(0x7C5CFF)

    enum Color {
        /// Window and mat base. Light: soft gray so white cards read against
        /// it. Dark: the original near-black (Raycast/Linear-style).
        static let canvasBase = themed(0xF2F2F6, 0x101013)
        /// Toolbar, tab strip, recognition panel.
        static let surface = themed(0xFFFFFF, 0x17171C)
        /// Floating panels, cards, input wells.
        static let raised = themed(0xFFFFFF, 0x1F1F26)
        static let hover = themed(0xECECF1, 0x26262E)
        /// Hairlines around panels and cards; a touch stronger on white than
        /// on near-black so the same hairline stays legible.
        static let stroke = dynamic(light: blackAlpha(0.12), dark: whiteAlpha(0.08))
        static let textPrimary = themed(0x1B1B21, 0xECECF1)
        static let textSecondary = themed(0x6A6A74, 0x9B9BA5)
        static let textTertiary = dynamic(light: blackAlpha(0.38), dark: whiteAlpha(0.4))
        static let accent = themed(0x6B4EFF, 0x7C5CFF)
        /// Accent fill behind selected tools and active tabs.
        static let accentSoft = dynamic(
            light: fixed(0x6B4EFF, 0.24),
            dark: fixed(0x7C5CFF, 0.24)
        )
        /// Faint resting wash that reads on both themes — white on dark,
        /// black on light: icon-button resting fills, input wells, settings
        /// tab hovers.
        static let subtleWash = dynamic(light: blackAlpha(0.06), dark: whiteAlpha(0.06))
        /// Base of the hover/press washes on themed buttons; `Alpha` supplies
        /// the level at draw time.
        static let washBase = dynamic(light: .black, dark: .white)

        private static func themed(_ light: UInt32, _ dark: UInt32) -> NSColor {
            dynamic(light: fixed(light), dark: fixed(dark))
        }

        private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        }

        fileprivate static func fixed(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
            NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha
            )
        }

        fileprivate static func blackAlpha(_ alpha: CGFloat) -> NSColor {
            NSColor.black.withAlphaComponent(alpha)
        }

        fileprivate static func whiteAlpha(_ alpha: CGFloat) -> NSColor {
            NSColor.white.withAlphaComponent(alpha)
        }
    }

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
        static let panel: CGFloat = 12
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

    /// Shadow strengths for floating surfaces. Read at surface creation, so a
    /// surface keeps the shadow of the theme it was built in; the next window
    /// picks up the new theme. Shadows stay black in both themes — only the
    /// opacity changes, since near-black needs a heavier shadow to separate.
    enum Shadow {
        @MainActor static var panelOpacity: Float { themeIsDark ? 0.5 : 0.22 }
        static let panelRadius: CGFloat = 18
        @MainActor static var cardOpacity: Float { themeIsDark ? 0.06 : 0.08 }
        static let cardRadius: CGFloat = 2
        @MainActor static var cardHoverOpacity: Float { themeIsDark ? 0.13 : 0.18 }
        static let cardHoverRadius: CGFloat = 14

        @MainActor private static var themeIsDark: Bool {
            guard let appearance = NSApp?.effectiveAppearance else { return true }
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    /// Fixed white/black for overlays drawn on top of screenshot content; these
    /// intentionally do not follow the theme.
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
